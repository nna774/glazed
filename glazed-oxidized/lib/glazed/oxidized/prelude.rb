# typed: ignore
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

# Derived from Oxidized (https://github.com/ytti/oxidized) lib/refinements.rb,
# lib/oxidized/model/model.rb, lib/oxidized/model/outputs.rb and
# lib/oxidized/input/{cli,ssh,telnet}.rb,
# Copyright 2013-2015 Saku Ytti, Samer Abdel-Hafez and Oxidized contributors,
# licensed under the Apache License, Version 2.0. Modified to run on glazed.

# The part of Oxidized's API that model files use. Loaded inside the
# Ruby::Box of each model, never into the main box; input classes reach the
# device through a {Glazed::Oxidized::Bridge}.

# String helpers that models activate with `using Refinements`.
module Refinements
  refine String do
    attr_accessor :type, :cmd, :name

    # @param lines [Integer] lines to remove
    # @return [String] copy of self without the last lines
    #: (?Integer lines) -> String
    def cut_tail(lines = 1)
      return "" if length.zero?

      each_line.to_a[0..(-1 - lines)].join
    end

    # @param lines [Integer] lines to remove
    # @return [String] copy of self without the first lines
    #: (?Integer lines) -> String
    def cut_head(lines = 1)
      return "" if length.zero?

      each_line.to_a[lines..].join
    end

    # @param head [Integer] leading lines to remove
    # @param tail [Integer] trailing lines to remove
    # @return [String] copy of self without the first and last lines
    #: (?Integer head, ?Integer tail) -> String
    def cut_both(head = 1, tail = 1)
      return "" if length.zero?

      each_line.to_a[head..(-1 - tail)].join
    end

    # Records the command that produced this output.
    #
    # @param command [String] command line
    # @return [String] the output name
    #: (String command) -> String
    def process_cmd(command)
      @cmd = command
      @name ||= @cmd.to_s.strip.gsub(/\s+/, '_')
    end

    # Copies command, name and type from another output.
    #
    # @param str [String] output to copy from
    # @return [void]
    # @raise [TypeError] when str is not a String
    #: (?String str) -> void
    def init_from_string(str = '')
      raise TypeError unless str.instance_of?(String)

      @cmd = str.instance_variable_get(:@cmd)
      @name = str.instance_variable_get(:@name)
      @type = str.instance_variable_get(:@type)
    end
  end
end

using Refinements

# Oxidized's namespace as model files see it.
module Oxidized
  # Base class of errors models raise.
  class OxidizedError < StandardError; end
  # Raised when the device prompt cannot be detected.
  class PromptUndetect < OxidizedError; end
  # Raised for features this compatibility layer lacks.
  class NotSupported < OxidizedError; end

  # Logger handed to models, writing warnings and errors to standard error.
  class Logger
    %i[debug info].each do |level|
      define_method(level) { |*| nil }
    end

    %i[warn error fatal].each do |level|
      define_method(level) { |message = nil, &block| $stderr.puts("oxidized model #{level}: #{message || block&.call}") }
    end
  end

  # @return [Logger] logger for models
  #: () -> Logger
  def self.logger
    @logger ||= Logger.new
  end

  # Configuration access, limited to variables.
  class Config
    # Variable lookup shared by models and inputs.
    module Vars
      # @param name [Symbol, String] variable name
      # @return [Object, nil] the node's variable
      #: (Symbol | String name) -> untyped
      def vars(name)
        @node&.vars&.[](name.to_sym)
      end
    end
  end

  # Base class of device models.
  class Model
    include Oxidized::Config::Vars

    class << self
      # Starts or inherits declarations for a new model.
      #
      # @param klass [Class] the new model
      # @return [void]
      #: (untyped klass) -> void
      def inherited(klass)
        super
        if klass.superclass == Oxidized::Model
          klass.instance_variable_set '@cmd', Hash.new { |h, k| h[k] = [] }
          klass.instance_variable_set '@cfg', Hash.new { |h, k| h[k] = [] }
          klass.instance_variable_set '@procs', Hash.new { |h, k| h[k] = [] }
          klass.instance_variable_set '@expect', []
          klass.instance_variable_set '@comment', nil
          klass.instance_variable_set '@prompt', nil
        else
          instance_variables.each do |var|
            iv = instance_variable_get(var)
            klass.instance_variable_set var, iv.dup
            @cmd[:cmd] = iv[:cmd].dup if var.to_s == "@cmd"
          end
        end
      end

      # Declares or reads the comment prefix.
      #
      # @param str [String] prefix used when none is declared yet
      # @return [String] the comment prefix
      #: (?String str) ?{ () -> String } -> String
      def comment(str = "# ")
        @comment = if block_given?
          yield
        elsif !@comment
          str
        else
          @comment
        end
      end

      # Declares or reads the prompt pattern.
      #
      # @param regex [Regexp, nil] prompt pattern
      # @return [Regexp, nil] the prompt pattern
      #: (?Regexp? regex) -> Regexp?
      def prompt(regex = nil)
        @prompt = regex || @prompt
      end

      # Declares blocks evaluated on the input for transports.
      #
      # @param methods [Array<Symbol>] transport names
      # @param args [Hash] :clear or :prepend
      # @return [void]
      #: (*Symbol methods, **untyped args) { () -> void } -> void
      def cfg(*methods, **args, &block)
        [methods].flatten.each do |method|
          process_args_block(@cfg[method.to_s], args, block)
        end
      end

      # @return [Hash{String => Array<Proc>}] cfg blocks by transport name
      #: () -> Hash[String, Array[Proc]]
      def cfgs
        @cfg
      end

      # Declares a command, or a block for :all or :secret outputs.
      #
      # @param cmd_arg [String, Symbol, Proc] command line, or :all or :secret
      # @param args [Hash] :clear or :prepend
      # @return [void]
      #: (?untyped cmd_arg, **untyped args) ?{ (String) -> untyped } -> void
      def cmd(cmd_arg = nil, **args, &block)
        if cmd_arg.instance_of?(Symbol)
          process_args_block(@cmd[cmd_arg], args, block)
        else
          process_args_block(@cmd[:cmd], args, [cmd_arg, block])
        end
      end

      # @return [Hash{Symbol => Array}] declared commands and blocks
      #: () -> Hash[Symbol, Array[untyped]]
      def cmds
        @cmd
      end

      # Declares a response to a pattern in received data.
      #
      # @param regex [Regexp] pattern to watch for
      # @param args [Hash] :clear or :prepend
      # @return [void]
      #: (Regexp regex, **untyped args) { (String) -> String } -> void
      def expect(regex, **args, &block)
        process_args_block(@expect, args, [regex, block])
      end

      # @return [Array<Array(Regexp, Proc)>] declared responses
      #: () -> Array[[Regexp, Proc]]
      def expects
        @expect
      end

      # Declares a block whose output is prepended.
      #
      # @param args [Hash] :clear or :prepend
      # @return [void]
      #: (**untyped args) { () -> String } -> void
      def pre(**args, &block)
        process_args_block(@procs[:pre], args, block)
      end

      # Declares a block whose output is appended.
      #
      # @param args [Hash] :clear or :prepend
      # @return [void]
      #: (**untyped args) { () -> String } -> void
      def post(**args, &block)
        process_args_block(@procs[:post], args, block)
      end

      # @return [Hash{Symbol => Array<Proc>}] :pre and :post blocks
      #: Hash[Symbol, Array[Proc]]
      attr_reader :procs

      # @param target [Array] list to add to
      # @param args [Hash] :clear or :prepend
      # @param block [Proc, Array] entry to add
      # @return [void]
      #: (Array[untyped] target, Hash[Symbol, untyped] args, untyped block) -> void
      private def process_args_block(target, args, block)
        if args[:clear]
          if block.instance_of?(Array)
            target.reject! { |k, _| k == block[0] }
            target.push(block)
          else
            target.replace([block])
          end
        else
          method = args[:prepend] ? :unshift : :push
          target.send(method, block)
        end
      end
    end

    # @return [Input] input talking to the device
    #: Input
    attr_accessor :input
    # @return [Glazed::Oxidized::NodeView] node being collected
    #: untyped
    attr_accessor :node

    # Runs a command through the :all, :secret and given blocks.
    #
    # @param string [String] command line
    # @return [String, false] processed output, or false when the input returned none
    #: (String string) ?{ (String) -> untyped } -> (String | false)
    def cmd(string, &block)
      out = @input.cmd(string)
      return false unless out

      self.class.cmds[:all].each do |all_block|
        out = instance_exec out, string, &all_block
      end
      if vars :remove_secret
        self.class.cmds[:secret].each do |all_block|
          out = instance_exec out, string, &all_block
        end
      end
      out = instance_exec out, &block if block
      process_cmd_output out, string
    end

    # @return [String] data the input received last
    #: () -> String
    def output
      @input.output
    end

    # Sends raw data.
    #
    # @param data [String] data to send
    # @return [void]
    #: (String data) -> void
    def send(data)
      @input.send data
    end

    # @return [void]
    #: (*untyped) -> void
    def expect(...)
      self.class.expect(...)
    end

    # @return [Hash{String => Array<Proc>}] cfg blocks by transport name
    #: () -> Hash[String, Array[Proc]]
    def cfg
      self.class.cfgs
    end

    # @return [Regexp, nil] the prompt pattern
    #: () -> Regexp?
    def prompt
      self.class.prompt
    end

    # Applies every declared response whose pattern matches.
    #
    # @param data [String] received data
    # @return [String] data after the responses
    #: (String data) -> String
    def expects(data)
      self.class.expects.each do |re, cb|
        data = run_expect(re, cb, data) if data.match re
      end
      data
    end

    # Collects the outputs of every command and the pre and post blocks.
    #
    # @return [Outputs, false] the outputs, or false when a command returned none
    #: () -> (Outputs | false)
    def get
      outputs = Outputs.new
      procs = self.class.procs
      self.class.cmds[:cmd].each do |command, block|
        out = cmd command, &block
        return false unless out

        outputs << out
      end
      procs[:pre].each do |pre_proc|
        outputs.unshift process_cmd_output(instance_eval(&pre_proc), '')
      end
      procs[:post].each do |post_proc|
        outputs << process_cmd_output(instance_eval(&post_proc), '')
      end
      outputs
    end

    # @param str [String] text to comment out
    # @return [String] every line prefixed with the comment prefix
    #: (String str) -> String
    def comment(str)
      data = String.new('')
      str.each_line do |line|
        data << self.class.comment << line
      end
      data
    end

    # @param str [String] text to comment out
    # @return [String] the text as XML comments
    #: (String str) -> String
    def xmlcomment(str)
      data = String.new('')
      str.each_line do |_line|
        data << '<!-- ' << str.gsub(/-(?=-)/, '- ').chomp << " -->\n"
      end
      data
    end

    # @return [Boolean] whether commands run on an interactive shell
    #: () -> untyped
    def screenscrape
      @input.class.to_s.match(/Telnet/) || vars(:ssh_no_exec)
    end

    # Applies one declared response.
    #
    # @param index [Integer] position of the response
    # @param data [String] received data
    # @return [String] data after the response
    #: (Integer index, String data) -> String
    def glazed_expect(index, data)
      re, cb = self.class.expects.fetch(index)
      run_expect(re, cb, data)
    end

    # @return [String, nil] the configuration, or nil when a command returned none
    #: () -> String?
    def glazed_get
      outputs = get
      outputs ? outputs.to_cfg : nil
    end

    # @param re [Regexp] pattern of the response
    # @param cb [Proc] the response
    # @param data [String] received data
    # @return [String] data after the response
    #: (Regexp re, Proc cb, String data) -> String
    private def run_expect(re, cb, data)
      cb.arity == 2 ? instance_exec([data, re], &cb) : instance_exec(data, &cb)
    end

    # @param output [Object] block result
    # @param name [String] command line
    # @return [String] the output, an empty String unless it is one
    #: (untyped output, String name) -> String
    private def process_cmd_output(output, name)
      output = String.new('') unless output.instance_of?(String)
      output.process_cmd(name)
      output
    end

    # Outputs of a model run.
    class Outputs
      #: () -> void
      def initialize
        @outputs = []
      end

      # @return [String] outputs without a type, joined
      #: () -> String
      def to_cfg
        type_to_str(nil)
      end

      # @param want_type [String, nil] output type
      # @return [String] outputs of the type, joined
      #: (String? want_type) -> String
      def type_to_str(want_type)
        type(want_type).join
      end

      # @param output [String] output to append
      # @return [void]
      #: (String output) -> void
      def <<(output)
        @outputs << output
      end

      # @param output [String] output to prepend
      # @return [void]
      #: (String output) -> void
      def unshift(output)
        @outputs.unshift output
      end

      # @return [Array<String>] every output
      #: () -> Array[String]
      def all
        @outputs
      end

      # @param type [String, nil] output type
      # @return [Array<String>] outputs of the type
      #: (String? type) -> Array[String]
      def type(type)
        @outputs.select { |out| out.type == type }
      end

      # @return [Array<String>] output types
      #: () -> Array[String]
      def types
        @outputs.map(&:type).uniq.compact
      end
    end
  end

  # Base class of inputs, which carry commands to the device through a bridge.
  class Input
    include Oxidized::Config::Vars

    # Connects the input to a bridge and a node.
    #
    # @param bridge [Glazed::Oxidized::Bridge] session to the device
    # @param node [Glazed::Oxidized::NodeView, nil] node being collected
    # @return [self]
    #: (untyped bridge, untyped node) -> self
    def glazed_attach(bridge, node)
      @glazed_bridge = bridge
      @node = node
      self
    end

    # Sends raw data.
    #
    # @param data [String] data to send
    # @return [void]
    #: (String data) -> void
    def send(data)
      @glazed_bridge.write(data)
    end

    # @return [String] data received but not consumed yet
    #: () -> String
    def output
      @glazed_bridge.output
    end

    # Login and logout handling of command-line inputs.
    module CLI
      # @return [Glazed::Oxidized::NodeView, nil] node being collected
      #: untyped
      attr_reader :node

      # Starts with no login handling declared.
      #: () -> void
      def initialize
        @post_login = []
        @pre_logout = []
        @username, @password, @exec = nil
      end

      # Runs the post_login commands and blocks.
      #
      # @return [void]
      #: () -> void
      def connect_cli
        @post_login.each { |command, block| block ? block.call : cmd(command) }
      end

      # Runs the pre_logout commands and blocks.
      #
      # @return [void]
      #: () -> void
      def disconnect_cli
        @pre_logout.each { |command, block| block ? block.call : cmd(command, nil) }
      end

      # Declares a command or block run after login.
      #
      # @param cmd [String, nil] command line
      # @return [void]
      #: (?String? cmd) ?{ () -> void } -> void
      def post_login(cmd = nil, &block)
        return if @exec

        @post_login << [cmd, block]
      end

      # Declares a command or block run before logout.
      #
      # @param cmd [String, nil] command line
      # @return [void]
      #: (?String? cmd) ?{ () -> void } -> void
      def pre_logout(cmd = nil, &block)
        return if @exec

        @pre_logout << [cmd, block]
      end

      # Declares the user name prompt.
      #
      # @param regex [Regexp] prompt pattern
      # @return [Regexp] the declared pattern
      #: (?Regexp regex) -> Regexp
      def username(regex = /^(Username|login)/)
        @username || (@username = regex)
      end

      # Declares the password prompt.
      #
      # @param regex [Regexp] prompt pattern
      # @return [Regexp] the declared pattern
      #: (?Regexp regex) -> Regexp
      def password(regex = /^Password/)
        @password || (@password = regex)
      end

      # @return [Regexp, nil] the declared user name prompt
      #: () -> Regexp?
      def glazed_username_prompt = @username

      # @return [Regexp, nil] the declared password prompt
      #: () -> Regexp?
      def glazed_password_prompt = @password

      # @return [Boolean] whether commands run on exec channels
      #: () -> bool
      def glazed_exec? = @exec ? true : false

      # Waits for one of the patterns.
      #
      # @param regexps [Array<Regexp>] patterns
      # @return [Regexp] the pattern that matched
      #: (*Regexp regexps) -> Regexp
      private def expect(*regexps)
        @glazed_bridge.expect(regexps.flatten)
      end
    end
  end

  # Input over SSH.
  class SSH < Input
    include Input::CLI

    # Raised when no shell can be opened.
    class NoShell < OxidizedError; end

    # Runs a command.
    #
    # @param cmd [String] command line
    # @param expect [Regexp, Array<Regexp>, nil] patterns ending the output; nil only sends the line
    # @return [String] output including the echoed command and the prompt, unless on an exec channel
    #: (String cmd, ?untyped expect) -> String
    def cmd(cmd, expect = node.prompt)
      @glazed_bridge.cmd(cmd, expect, exec: glazed_exec?)
    end

    # PTY options are left to the glazed transport.
    #
    # @param _hash [Hash] PTY options
    # @return [void]
    #: (Hash[Symbol, untyped] _hash) -> void
    def pty_options(_hash); end

    # Declares or reads whether commands run on exec channels.
    #
    # @param state [Boolean, nil] true to use exec channels
    # @return [Boolean, nil] the setting
    #: (?bool? state) -> bool?
    private def exec(state = nil)
      return nil if vars(:ssh_no_exec)

      state.nil? ? @exec : (@exec = state)
    end
  end

  # Input over Telnet.
  class Telnet < Input
    include Input::CLI

    # Runs a command.
    #
    # @param cmd_str [String] command line
    # @param expect [Regexp, Array<Regexp>, nil] patterns ending the output; nil only sends the line
    # @return [String] output including the echoed command and the prompt
    #: (String cmd_str, ?untyped expect) -> String
    def cmd(cmd_str, expect = @node.prompt)
      unless expect
        send(cmd_str + "\r\n")
        return String.new('')
      end

      @glazed_bridge.cmd(cmd_str, expect, exec: false)
    end
  end
end
