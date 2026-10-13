# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'fileutils'
require 'open3'
require 'glazed'
require 'glazed/must'
require 'glazed/proto'
require 'glazed/storages/base'

module Glazed
  module Storages
    # Local git repository driven by the git command. Each write is one commit
    # on the configured branch, optionally pulled before and pushed after.
    #
    # @example
    #   storage = Glazed::Storages::Git.new(path: '/var/lib/glazed/raw')
    #   storage.write(key: 'core/rt1', content: config, message: 'rt1')
    class Git < Base
      # Raised when a git command fails.
      class CommandFailed < Glazed::Error; end

      # Branch used when none is configured.
      DEFAULT_BRANCH = 'main' #: String
      # Author name used when none is configured.
      DEFAULT_AUTHOR_NAME = 'glazed' #: String
      # Author email used when none is configured.
      DEFAULT_AUTHOR_EMAIL = 'glazed@localhost' #: String

      # @param path [String] working tree, initialised when missing
      # @param branch [String] branch to commit to
      # @param remote [String, nil] remote name or URL to pull from and push to
      # @param author_name [String] commit author and committer name
      # @param author_email [String] commit author and committer email
      #: (path: String, ?branch: String, ?remote: String?, ?author_name: String, ?author_email: String) -> void
      def initialize(path:, branch: DEFAULT_BRANCH, remote: nil, author_name: DEFAULT_AUTHOR_NAME, author_email: DEFAULT_AUTHOR_EMAIL)
        super()
        @path = path #: String
        @branch = branch #: String
        @remote = remote #: String?
        @author_name = author_name #: String
        @author_email = author_email #: String
        @lock = Mutex.new #: Thread::Mutex
      end

      # Builds a storage from {Proto::V1::GitStorage}.
      #
      # @param settings [Google::Protobuf::MessageExts] a {Proto::V1::GitStorage}
      # @return [Git] the storage
      # @raise [Must::Violation] when settings is another message
      #: (Google::Protobuf::MessageExts settings) -> Git
      def self.from_proto(settings)
        git = Must.be_a(settings, Proto::V1::GitStorage)
        new(
          path: git.path,
          branch: git.branch.empty? ? DEFAULT_BRANCH : git.branch,
          remote: git.remote.empty? ? nil : git.remote,
          author_name: git.author_name.empty? ? DEFAULT_AUTHOR_NAME : git.author_name,
          author_email: git.author_email.empty? ? DEFAULT_AUTHOR_EMAIL : git.author_email,
        )
      end

      # @return [String] working tree
      #: String
      attr_reader :path
      # @return [String] branch to commit to
      #: String
      attr_reader :branch
      # @return [String, nil] remote name or URL
      #: String?
      attr_reader :remote

      # Writes files in one commit. Nothing is committed when no content
      # changed, and the pointers then name the existing HEAD.
      #
      # @param files [Array<Array(String, String)>] keys and contents
      # @param message [Proc] builds the commit message from the changed keys
      # @return [Array<WriteResult>] the commit holding each file, and whether the file changed
      # @raise [InvalidKey] for an unsafe key
      # @raise [CommandFailed] when a git command fails
      #: (Array[Base::file] files, message: Base::message_builder) -> Array[WriteResult]
      def write_all(files, message:)
        keys = files.map { |key, _| validate_key(key) }
        @lock.synchronize do
          prepare
          files.each do |key, content|
            file = File.join(path, key)
            FileUtils.mkdir_p(File.dirname(file))
            File.write(file, content)
          end
          git(['add', '--', *keys])
          changed = git(['diff', '--cached', '--name-only', '-z', '--', *keys]).split("\0")
          unless changed.empty?
            git(['commit', '--quiet', '--no-verify', '-m', message.call(changed)])
            git(['push', '--quiet', Must.expect(remote), "HEAD:refs/heads/#{branch}"]) if remote
          end
          commit = git(%w[rev-parse HEAD]).strip
          keys.map do |key|
            WriteResult.new(pointer: Proto::V1::Pointer.new(git: Proto::V1::GitLocation.new(path: key, commit:)), changed: changed.include?(key))
          end
        end
      end

      # Reads a file at the commit a pointer names.
      #
      # @param pointer [Proto::V1::Pointer] pointer with a git location
      # @return [String] the content
      # @raise [ArgumentError] when the pointer is not a git location
      # @raise [CommandFailed] when the commit or path does not exist
      #: (Proto::V1::Pointer pointer) -> String
      def read(pointer)
        location = pointer.git or raise ArgumentError, "not a git pointer: #{pointer.location.inspect}"
        git(['show', "#{location.commit}:#{validate_key(location.path)}"])
      end

      # Initialises the repository when missing, switches to the branch and
      # pulls it from the remote when it exists there.
      #
      # @return [void]
      # @raise [CommandFailed] when a git command fails
      #: () -> void
      private def prepare
        unless File.exist?(File.join(path, '.git'))
          FileUtils.mkdir_p(path)
          git(['init', '--quiet', "--initial-branch=#{branch}"])
        end
        unless run_git(%w[symbolic-ref --quiet --short HEAD])[0].strip == branch
          git_success?(['switch', '--quiet', branch]) || git(['switch', '--quiet', '--create', branch])
        end
        pull if remote
      end

      # @return [void]
      # @raise [CommandFailed] when the pull fails
      #: () -> void
      private def pull
        remote = Must.expect(self.remote)
        return unless git_success?(['ls-remote', '--exit-code', '--heads', remote, branch])

        git(['pull', '--quiet', '--ff-only', remote, branch])
      end

      # @param args [Array<String>] git arguments
      # @return [String] standard output
      # @raise [CommandFailed] when git exits non-zero, with its error output
      #: (Array[String] args) -> String
      private def git(args)
        output, status = run_git(args)
        raise CommandFailed, "git #{args.first} failed in #{path}: #{output.strip}" unless status.success?

        output
      end

      # @param args [Array<String>] git arguments
      # @return [Boolean] whether git exits zero
      #: (Array[String] args) -> bool
      private def git_success?(args) = run_git(args)[1].success? || false

      # @param args [Array<String>] git arguments
      # @return [Array(String, Process::Status)] output with errors merged in, and exit status
      #: (Array[String] args) -> [String, Process::Status]
      private def run_git(args)
        output = IO.popen(git_env, ['git', *args], chdir: path, err: %i[child out], &:read)
        [output, Process.last_status]
      end

      # @return [Hash{String => String}] environment fixing the identity used for commits
      #: () -> Hash[String, String]
      private def git_env
        {
          'GIT_AUTHOR_NAME' => @author_name,
          'GIT_AUTHOR_EMAIL' => @author_email,
          'GIT_COMMITTER_NAME' => @author_name,
          'GIT_COMMITTER_EMAIL' => @author_email,
        }
      end
    end
  end
end
