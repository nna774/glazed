# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'digest'
require 'httpx'
require 'uri'
require 'glazed'
require 'glazed/must'
require 'glazed/proto'
require 'glazed/secret'
require 'glazed/storages/base'
require 'glazed/version'

module Glazed
  module Storages
    # GitHub repository written through the Git Data API. Each write is one
    # commit on the branch, which is created from the base branch when missing.
    #
    # @example
    #   storage = Glazed::Storages::Github.new(repository: 'org/netconf', branch: 'glazed/auto', token:)
    #   storage.write(key: 'core/rt1', content: config, message: 'rt1')
    class Github < Base
      # Raised when the API answers with an error status.
      class ApiError < Glazed::Error
        # @param status [Integer] HTTP status
        # @param message [String] error description
        #: (status: Integer, message: String) -> void
        def initialize(status:, message:)
          super(message)
          @status = status #: Integer
        end

        # @return [Integer] HTTP status
        #: Integer
        attr_reader :status
      end

      # API endpoint used when none is configured.
      DEFAULT_API_URL = 'https://api.github.com' #: String
      # Attempts at moving the branch when another writer moved it first.
      MAX_ATTEMPTS = 3 #: Integer
      # REST API version requested.
      API_VERSION = '2022-11-28' #: String

      # @param repository [String] repository as "owner/name"
      # @param branch [String] branch to commit to
      # @param token [Secret] token with contents write permission
      # @param base_branch [String, nil] branch to start a missing branch from; the default branch when nil
      # @param api_url [String] API endpoint
      # @param author_name [String, nil] commit author name; the token owner when nil
      # @param author_email [String, nil] commit author email; the token owner when nil
      #: (repository: String, branch: String, token: Secret, ?base_branch: String?, ?api_url: String, ?author_name: String?, ?author_email: String?) -> void
      def initialize(repository:, branch:, token:, base_branch: nil, api_url: DEFAULT_API_URL, author_name: nil, author_email: nil)
        super()
        @repository = repository #: String
        @branch = branch #: String
        @token = token #: Secret
        @base_branch = base_branch #: String?
        @api_url = api_url.chomp('/') #: String
        @author = (author_name && author_email ? {name: author_name, email: author_email} : nil) #: Hash[Symbol, String]?
        @http = nil #: HTTPX::Session?
      end

      # Builds a storage from {Proto::V1::GithubStorage}.
      #
      # @param settings [Google::Protobuf::MessageExts] a {Proto::V1::GithubStorage}
      # @return [Github] the storage
      # @raise [Must::Violation] when settings is another message
      # @raise [ArgumentError] when the token is missing
      #: (Google::Protobuf::MessageExts settings) -> Github
      def self.from_proto(settings)
        github = Must.be_a(settings, Proto::V1::GithubStorage)
        new(
          repository: github.repository,
          branch: github.branch,
          token: Secret.maybe(github.token) || raise(ArgumentError, 'github storage needs a token'),
          base_branch: github.base_branch.empty? ? nil : github.base_branch,
          api_url: github.api_url.empty? ? DEFAULT_API_URL : github.api_url,
          author_name: github.author_name.empty? ? nil : github.author_name,
          author_email: github.author_email.empty? ? nil : github.author_email,
        )
      end

      # @return [String] repository as "owner/name"
      #: String
      attr_reader :repository
      # @return [String] branch to commit to
      #: String
      attr_reader :branch

      # Writes the changed files in one commit. Nothing is committed when no
      # content changed, and the pointers then name the existing head.
      #
      # @param files [Array<Array(String, String)>] keys and contents
      # @param message [Proc] builds the commit message from the changed keys
      # @return [Array<WriteResult>] the commit holding each file, and whether the file changed
      # @raise [InvalidKey] for an unsafe key
      # @raise [ApiError] when the API fails, or the branch keeps moving under concurrent writers
      #: (Array[Base::file] files, message: Base::message_builder) -> Array[WriteResult]
      def write_all(files, message:)
        keys = files.map { |key, _| validate_key(key) }
        commit, changed = with_retries { commit_files(files, message) }
        keys.map do |key|
          pointer = pointer_to(Proto::V1::GithubLocation.new(repository:, path: key, commit:))
          WriteResult.new(pointer:, changed: changed.include?(key))
        end
      end

      # Reads a file at the commit a pointer names.
      #
      # @param pointer [Proto::V1::Pointer] pointer with a github location
      # @return [String] the content
      # @raise [ArgumentError] when the pointer is not a github location
      # @raise [ApiError] when the file or commit does not exist
      #: (Proto::V1::Pointer pointer) -> String
      def read(pointer)
        location = location_of(pointer, Proto::V1::GithubLocation)
        path = "/repos/#{location.repository}/contents/#{escape(validate_key(location.path))}?ref=#{escape(location.commit)}"
        check(http.get(url(path), headers: {'accept' => 'application/vnd.github.raw+json'})).body.to_s
      end

      # @yieldreturn [Object] result of one attempt
      # @return [Object] result of the first attempt that succeeded
      # @raise [ApiError] when attempts run out
      #: [T] () { () -> T } -> T
      private def with_retries(&attempt)
        attempts = 0
        begin
          attempts += 1
          attempt.call
        rescue ApiError => e
          # 422 means the branch moved or appeared between reading and updating it.
          retry if e.status == 422 && attempts < MAX_ATTEMPTS
          raise
        end
      end

      # @param files [Array<Array(String, String)>] keys and contents
      # @param message [Proc] builds the commit message from the changed keys
      # @return [Array(String, Array<String>)] SHA of the commit holding the files, and the changed keys
      # @raise [ApiError] when the API fails
      #: (Array[Base::file] files, Base::message_builder message) -> [String, Array[String]]
      private def commit_files(files, message)
        head = ref_sha(branch)
        parent = head || ref_sha(base_branch) || raise(ApiError.new(status: 404, message: "#{repository}: base branch #{base_branch} not found"))
        base_tree = json(get("/repos/#{repository}/git/commits/#{parent}")).dig('tree', 'sha')
        existing = blob_shas(base_tree)
        candidates = existing ? files.reject { |key, content| existing[key] == blob_sha(content) } : files

        commit = parent
        changed = [] #: Array[String]
        unless candidates.empty?
          entries = candidates.map { |key, content| {path: key, mode: '100644', type: 'blob', content:} }
          tree = json(post("/repos/#{repository}/git/trees", {base_tree:, tree: entries})).fetch('sha')
          unless tree == base_tree
            changed = candidates.map(&:first)
            body = {message: message.call(changed), tree:, parents: [parent], author: @author}.compact
            commit = json(post("/repos/#{repository}/git/commits", body)).fetch('sha')
          end
        end

        if head.nil?
          post("/repos/#{repository}/git/refs", {ref: "refs/heads/#{branch}", sha: commit})
        elsif commit != head
          patch("/repos/#{repository}/git/refs/heads/#{escape(branch)}", {sha: commit, force: false})
        end
        [commit, changed]
      end

      # @param tree [String] tree SHA
      # @return [Hash{String => String}, nil] blob SHAs by path, or nil when GitHub truncates the listing
      # @raise [ApiError] when the tree cannot be read
      #: (String tree) -> Hash[String, String]?
      private def blob_shas(tree)
        listing = json(get("/repos/#{repository}/git/trees/#{tree}?recursive=1"))
        return nil if listing['truncated']

        entries = listing.fetch('tree') #: Array[Hash[String, String]]
        entries.select { it['type'] == 'blob' }.to_h { [it.fetch('path'), it.fetch('sha')] }
      end

      # @param content [String] file content
      # @return [String] git blob SHA-1 of the content
      #: (String content) -> String
      private def blob_sha(content) = Digest::SHA1.hexdigest("blob #{content.bytesize}\0".b + content.b)

      # @param name [String] branch name
      # @return [String, nil] SHA the branch points to, or nil when it does not exist
      # @raise [ApiError] for errors other than not found
      #: (String name) -> String?
      private def ref_sha(name)
        json(get("/repos/#{repository}/git/ref/heads/#{escape(name)}")).dig('object', 'sha')
      rescue ApiError => e
        raise unless e.status == 404

        nil
      end

      # @return [String] the configured base branch, or the repository default branch
      # @raise [ApiError] when the repository cannot be read
      #: () -> String
      private def base_branch
        @base_branch ||= json(get("/repos/#{repository}")).fetch('default_branch')
      end

      # @param path [String] API path
      # @return [HTTPX::Response] the successful response
      # @raise [ApiError] for an error status
      #: (String path) -> HTTPX::Response
      private def get(path) = check(http.get(url(path)))

      # @param path [String] API path
      # @param body [Hash] JSON body
      # @return [HTTPX::Response] the successful response
      # @raise [ApiError] for an error status
      #: (String path, Hash[Symbol, untyped] body) -> HTTPX::Response
      private def post(path, body) = check(http.post(url(path), json: body))

      # @param path [String] API path
      # @param body [Hash] JSON body
      # @return [HTTPX::Response] the successful response
      # @raise [ApiError] for an error status
      #: (String path, Hash[Symbol, untyped] body) -> HTTPX::Response
      private def patch(path, body) = check(http.patch(url(path), json: body))

      # @param response [HTTPX::Response] successful response
      # @return [Hash] its decoded JSON body
      #: (HTTPX::Response response) -> Hash[String, untyped]
      private def json(response) = response.json

      # @param response [HTTPX::Response, HTTPX::ErrorResponse] response to check
      # @return [HTTPX::Response] the response when its status is below 400
      # @raise [ApiError] for an error status
      # @raise [HTTPX::Error] for a transport failure
      #: (HTTPX::Response | HTTPX::ErrorResponse response) -> HTTPX::Response
      private def check(response)
        raise response.error if response.is_a?(HTTPX::ErrorResponse)
        return response if response.status < 400

        raise ApiError.new(status: response.status, message: "#{repository}: #{response.uri.path} returned #{response.status}: #{response.body}")
      end

      # @param path [String] API path starting with "/"
      # @return [String] absolute URL
      #: (String path) -> String
      private def url(path) = "#{@api_url}#{path}"

      # @param value [String] slash-separated value
      # @return [String] each segment percent-encoded
      #: (String value) -> String
      private def escape(value) = value.split('/', -1).map { URI.encode_uri_component(it) }.join('/')

      # @return [HTTPX::Session] session with authentication headers
      #: () -> HTTPX::Session
      private def http
        @http ||= HTTPX.plugin(:retries).with(
          headers: {
            'accept' => 'application/vnd.github+json',
            'authorization' => "Bearer #{@token.value}",
            'user-agent' => "glazed/#{Glazed::VERSION}",
            'x-github-api-version' => API_VERSION,
          },
        )
      end
    end
  end
end
