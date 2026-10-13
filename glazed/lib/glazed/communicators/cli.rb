# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

module Glazed
  module Communicators
    # Common interface for communicator with interactive session
    module Cli
      def buffer
        @buffer or init_buffer
      end

      private def init_buffer
        @buffer = String.new
      end

      def command(line)
        if @dialect&.exec && respond_to?(:exec)
          exec(line)
        else
          send(line)
          expect(prompt)
          buffer
        end
      end

      def expect(*patterns)
        wait_loop(0.1) do
          patterns.each do |pat|
            m = buffer.match(pat)
            return m if m
          end
        end
        nil
      end

      private def feed(data)
        filtered_data = data_filters.inject(data) do |r, filter|
          filter.call(r)
        end
        @buffer << filtered_data
        interactions.each do |interaction|
          m = interaction.pattern.match(@buffer)
          if m
            do_buffer_action(interaction.responder.call(self, @buffer.dup, m))
          end
        end
        nil
      end

      private def do_buffer_action(action)
        Glazed::Dialects::Base::Actions::Multi.maybe(action).actions.each do |action|
          case action
          when Glazed::Dialects::Base::Actions::Replace
            @buffer = action.content.dup
          when Glazed::Dialects::Base::Actions::Append
            @buffer << action.content
          when nil
          else
            raise TpeError, "Unknown action: #{action.inspect}"
          end
        end
      end

      def send(data)
        raise NotImplementedError
      end

      private def wait_loop(duration = 0.1, &callback)
        # placeholder implementation
        loop do
          sleep(duration)
          callback.call
        end
      end

      def configure(&block)
        d = DialectData.new
        block.call(d)
        @dialect = d
        nil
      end

      DialectData = Struct.new(:exec, :username_prompt, :password_prompt, :post_login_procs, :pre_logout_procs, keyword_init: true) do
        def post_login(&block)
          (post_login_procs ||= []) << block
          nil
        end

        def pre_logout(&block)
          (pre_logout_procs ||= []) << block
          nil
        end
      end
    end
  end
end
