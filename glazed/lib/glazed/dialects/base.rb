# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/dialect'
require 'glazed/dialect/actions'
require 'glazed/dialect/communication_config'
require 'glazed/dialect/interaction'
require 'glazed/dialect/runbook'
require 'glazed/dialect/sensitive_pattern'

module Glazed
  module Dialects
    # Base class of dialects. A dialect describes how to talk to one kind of
    # device and how to collect its configuration, through class-level
    # declarations that subclasses inherit.
    #
    # Lists (data and output filters, interactions, sensitive patterns,
    # communication blocks) accumulate from parent to child. The prompt, comment
    # prefix and each runbook are replaced by a child's own declaration.
    #
    # @example
    #   class Rootware < Glazed::Dialects::Base
    #     prompt(/^\S+[#>]\s?$/)
    #     comment_prefix '! '
    #     runbook :get do |book|
    #       book.command('show version') { |result| comment(result.output) }
    #       book.command('show running-config')
    #     end
    #   end
    class Base
      # Shorthand for {Dialect::Actions} inside dialect definitions.
      Actions = Glazed::Dialect::Actions

      # Comment prefix used when a dialect declares none.
      DEFAULT_COMMENT_PREFIX = '# ' #: String

      @parent = nil #: singleton(Base)?
      @prompt = nil #: Regexp?
      @comment_prefix = nil #: String?
      @data_filters = nil #: Array[Dialect::data_filter]?
      @output_filters = nil #: Array[Dialect::data_filter]?
      @interactions = nil #: Array[Dialect::Interaction]?
      @sensitive_patterns = nil #: Array[Dialect::SensitivePattern]?
      @communications = nil #: Array[[Array[Symbol], ^(Dialect::CommunicationConfig) -> void]]?
      @runbooks = nil #: Hash[Symbol, Dialect::Runbook]?


      class << self
        # Records the parent so subclasses inherit declarations.
        #
        # @param subclass [Class<Base>] the new dialect
        # @return [void]
        #: (singleton(Base) subclass) -> void
        def inherited(subclass)
          super
          subclass.parent = self
        end

        # Declares the command prompt pattern.
        #
        # @param pattern [Regexp] prompt pattern, matched against the session buffer
        # @return [void]
        # @example
        #   prompt(/^\S+[#>]\s?$/)
        #: (Regexp pattern) -> void
        def prompt(pattern)
          @prompt = pattern
        end

        # @return [Regexp] the declared or inherited prompt pattern
        # @raise [NotImplementedError] when no prompt is declared
        #: () -> Regexp
        def prompt_pattern
          @prompt || @parent&.prompt_pattern || raise(NotImplementedError, "#{name} declares no prompt")
        end

        # Declares the prefix of comment lines in collected configuration.
        #
        # @param prefix [String] such as "! " or "# "
        # @return [void]
        # @example
        #   comment_prefix '! '
        #: (String prefix) -> void
        def comment_prefix(prefix)
          @comment_prefix = prefix
        end

        # @return [String] the declared or inherited comment prefix
        #: () -> String
        def comment_prefix_value
          @comment_prefix || @parent&.comment_prefix_value || DEFAULT_COMMENT_PREFIX
        end

        # Turns text into comment lines.
        #
        # @param text [String] text to comment out
        # @return [String] every line prefixed, ending with a newline
        #: (String text) -> String
        def comment(text)
          prefix = comment_prefix_value
          text.each_line.map { |line| "#{prefix}#{line.chomp}".rstrip + "\n" }.join
        end

        # Declares a filter for each fragment of received data, such as one
        # removing ANSI sequences. Fragments split at arbitrary points.
        #
        # @yieldparam fragment [String] received data
        # @yieldreturn [String] filtered data
        # @return [void]
        # @example
        #   filter_data { |fragment| fragment.delete("\r") }
        #: () { (String fragment) -> String } -> void
        def filter_data(&filter)
          (@data_filters ||= []) << filter
        end

        # @return [Array<Proc>] inherited then own data filters
        #: () -> Array[Dialect::data_filter]
        def data_filters = (@parent&.data_filters || []) + (@data_filters || [])

        # Declares a filter for the whole output of each runbook command. The
        # output arrives as bytes and must be valid UTF-8 once every filter ran,
        # so a dialect for a device using another encoding converts it here.
        #
        # @yieldparam output [String] command output, as bytes (ASCII-8BIT)
        # @yieldreturn [String] filtered output
        # @return [void]
        # @example
        #   filter_output { |output| output.gsub(/ +$/, '') }
        #: () { (String output) -> String } -> void
        def filter_output(&filter)
          (@output_filters ||= []) << filter
        end

        # @return [Array<Proc>] inherited then own output filters
        #: () -> Array[Dialect::data_filter]
        def output_filters = (@parent&.output_filters || []) + (@output_filters || [])

        # Declares a response to a pattern appearing in the session buffer.
        # The responder must remove the pattern from the buffer, or it fires
        # again on the next received data.
        #
        # @param pattern [Regexp] pattern to watch for
        # @yieldparam session [CliSession] the session
        # @yieldparam buffer [String] copy of the buffer
        # @yieldparam match [MatchData] the match in the buffer
        # @yieldreturn [Actions::Append, Actions::Replace, Actions::Multi, String, nil] action applied to the buffer
        # @return [void]
        # @example
        #   interact(/--More--/) do |cli, _buffer, match|
        #     cli.write(' ')
        #     Actions::Replace.new(content: match.pre_match + match.post_match)
        #   end
        #: (Regexp pattern) { (CliSession session, String buffer, MatchData match) -> Dialect::Actions::action? } -> void
        def interact(pattern, &responder)
          (@interactions ||= []) << Dialect::Interaction.new(pattern:, responder:)
        end

        # @return [Array<Dialect::Interaction>] inherited then own interactions
        #: () -> Array[Dialect::Interaction]
        def interactions = (@parent&.interactions || []) + (@interactions || [])

        # Declares where secrets appear in collected configuration.
        #
        # @param pattern [Regexp] pattern matched against the whole configuration
        # @yieldparam match [MatchData] a match
        # @yieldreturn [String, Range<Integer>, nil] the secret within the match, or its offsets in the configuration
        # @return [void]
        # @example
        #   sensitive_pattern(/^enable secret \d (\S+)/) { it[1] }
        #: (Regexp pattern) { (MatchData match) -> (String | Range[Integer])? } -> void
        def sensitive_pattern(pattern, &determiner)
          (@sensitive_patterns ||= []) << Dialect::SensitivePattern.new(pattern:, determiner:)
        end

        # @return [Array<Dialect::SensitivePattern>] inherited then own sensitive patterns
        #: () -> Array[Dialect::SensitivePattern]
        def sensitive_patterns = (@parent&.sensitive_patterns || []) + (@sensitive_patterns || [])

        # Declares communication settings for transports.
        #
        # @param kinds [Array<Symbol>] transport names, such as :ssh and :telnet
        # @yieldparam config [Dialect::CommunicationConfig] config to adjust
        # @return [void]
        # @example
        #   communication :ssh, :telnet do |config|
        #     config.post_login { |run| run.cli.command('terminal length 0') }
        #   end
        #: (*Symbol kinds) { (Dialect::CommunicationConfig config) -> void } -> void
        def communication(*kinds, &configure)
          (@communications ||= []) << [kinds, configure]
        end

        # Builds the communication settings for a transport.
        #
        # @param kind [Symbol] transport name
        # @return [Dialect::CommunicationConfig] config with inherited then own blocks applied
        #: (Symbol kind) -> Dialect::CommunicationConfig
        def communication_config(kind)
          config = @parent&.communication_config(kind) || Dialect::CommunicationConfig.new
          (@communications || []).each do |kinds, configure|
            configure.call(config) if kinds.include?(kind)
          end
          config
        end

        # Declares the runbook for an operation, replacing any inherited one.
        #
        # @param operation [Symbol] operation name; :get collects the configuration
        # @yieldparam book [Dialect::Runbook::Builder] builder to add steps to
        # @return [void]
        # @example
        #   runbook :get do |book|
        #     book.command('show running-config')
        #   end
        #: (Symbol operation) { (Dialect::Runbook::Builder book) -> void } -> void
        def runbook(operation, &definition)
          builder = Dialect::Runbook::Builder.new
          definition.call(builder)
          (@runbooks ||= {})[operation] = builder.build
        end

        # @param operation [Symbol] operation name
        # @return [Dialect::Runbook] the declared or inherited runbook
        # @raise [NotImplementedError] when no runbook is declared for the operation
        #: (Symbol operation) -> Dialect::Runbook
        def runbook_for(operation)
          @runbooks&.[](operation) || @parent&.runbook_for(operation) ||
            raise(NotImplementedError, "#{name} declares no #{operation} runbook")
        end

        # @param parent [Class<Base>, nil] dialect to inherit declarations from
        # @return [void]
        #: (singleton(Base)? parent) -> void
        protected def parent=(parent)
          @parent = parent
        end
      end

      # A PTY ends lines with CRLF; normalised on whole output, as a fragment may split the pair.
      filter_output { it.gsub(/\r+\n/, "\n") }
    end
  end
end
