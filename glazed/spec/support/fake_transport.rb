# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/transports/base'

# Scripted device. Each line written is echoed (unless echo: false) and answered from responses,
# keyed by the exact line or a Regexp. A response may be paged with a pager
# prompt that waits for a space.
class FakeTransport < Glazed::Transports::Base
  class UnexpectedInput < StandardError; end

  def initialize(responses: {}, greeting: '', pager: nil, more: '--More--', exec_responses: nil, authenticates: true, echo: true)
    super(host: 'fake', port: nil, username: 'user', password: nil)
    @responses = responses
    @greeting = greeting
    @pager = pager
    @more = more
    @exec_responses = exec_responses
    @authenticates = authenticates
    @echo = echo
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
      elsif char.ord < 0x20
        # Control keys such as Ctrl-Z act at once; they are answered only when scripted.
        respond(char) if @responses.key?(char)
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
    @outbox << "#{line}\r\n" if @echo
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

class FakeTransport
  # A transport class whose instances, however constructed, play the given
  # script. Built instances are kept in .instances.
  def self.device(**script)
    parent = self
    Class.new(self) do
      instances = []
      define_singleton_method(:new) { |**_connection| parent.new(**script).tap { instances << it } }
      define_singleton_method(:instances) { instances }
    end
  end
end
