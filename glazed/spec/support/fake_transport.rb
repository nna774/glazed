# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/transports/base'

# Scripted device. Each line written is echoed and answered from responses,
# keyed by the exact line or a Regexp. A response may be paged with a pager
# prompt that waits for a space.
class FakeTransport < Glazed::Transports::Base
  class UnexpectedInput < StandardError; end

  def initialize(responses: {}, greeting: '', pager: nil, more: '--More--', exec_responses: nil, authenticates: true)
    super(host: 'fake', port: nil, username: 'user', password: nil)
    @responses = responses
    @greeting = greeting
    @pager = pager
    @more = more
    @exec_responses = exec_responses
    @authenticates = authenticates
    @outbox = []
    @pending_pages = []
    @line = +''
    @written = []
    @closed = false
  end

  attr_reader :written

  def open
    @outbox << @greeting unless @greeting.empty?
  end

  def write(data)
    @written << data
    data.each_char do |char|
      if !@pending_pages.empty? && char == ' '
        emit_page
      elsif char == "\n" || char == "\r"
        respond(@line)
        @line = +''
      else
        @line << char
      end
    end
  end

  def read(timeout:)
    return nil if @closed && @outbox.empty?

    @outbox.shift || +''
  end

  def close
    @closed = true
  end

  def closed? = @closed

  def authenticates? = @authenticates

  def exec? = !@exec_responses.nil?

  def exec(command, timeout:)
    @exec_responses.fetch(command) { raise UnexpectedInput, "unexpected exec #{command.inspect}" }
  end

  private def respond(line)
    _, response = @responses.find { |key, _| key.is_a?(Regexp) ? key.match?(line) : key == line }
    raise UnexpectedInput, "unexpected input #{line.inspect}" unless response

    response = response.call(line) if response.respond_to?(:call)
    @outbox << "#{line}\r\n"
    return @outbox << response unless @pager

    @pending_pages = response.lines.each_slice(@pager).map(&:join)
    emit_page
  end

  private def emit_page
    page = @pending_pages.shift
    @outbox << page
    @outbox << @more unless @pending_pages.empty?
  end
end
