# coding: utf-8

require 'logger'
require 'rubo/adapters'
require 'rubo/brain'
require 'rubo/error'
require 'rubo/eval_context'
require 'rubo/event_emitter'
require 'rubo/listener'
require 'rubo/message'
require 'rubo/response'

module Rubo
  # Robots receive messages from a chat source (Shell, irc, etc), and
  # dispatch them to matching listeners.
  class Robot
    include EventEmitter

    # @return [Symbol, String]
    attr_reader :name

    # @return [Brain]
    attr_reader :brain

    # @return [Symbol, String]
    attr_accessor :alias_name

    # @return [Adaptable]
    attr_accessor :adapter

    # @return [Class<Response>]
    attr_accessor :response

    # @param adapter_name [Symbol, String] A String of the adapter name.
    # @param name [Symbol, String] A String of the robot name, defaults to Rubo.
    def initialize(adapter_name, name = :Rubo)
      @name           = name
      @alias_name     = false
      @adapter        = nil
      @brain          = Brain.new(self)
      @response       = Response
      @commands       = []
      @listeners      = []
      @error_handlers = []
      load_adapter(adapter_name)
      on(:error) do |error, message|
        invoke_error_handlers(error, message)
      end
    end

    # Returns a shared logger of Rubo
    #
    # @return [Logger]
    def logger
      Rubo.logger
    end

    # Help Commands for Running Scripts.
    #
    # @return [Array<String>]
    def commands
      @commands.sort
    end

    # Adds a Listener that attempts to match incoming messages based on a Regex.
    #
    # @param regex [Regexp] A Regex that determines
    #   if the callback should be called.
    # @yield [message] A Function that is called with a Response object.
    # @yieldparam message [Response]
    # @return [void]
    def hear(regex, &block)
      @listeners << TextListener.new(self, regex, &block)
    end

    # Adds a Listener that attempts to match incoming messages directed
    # at the # robot based on a Regex.
    # All regexes treat patterns like they begin with a '^'
    #
    # @param regex [Regexp] A Regex that determines
    #   if the callback should be called.
    # @yield [message] A Function that is called with a Response object.
    # @yieldparam message [Response]
    # @return [void]
    def respond(regex, &block)
      pattern = regex.source
      options = regex.options
      if pattern[0] == '^'
        logger.warn \
          "Anchors don't work well with respond, perhaps you want to use 'hear'"
        logger.warn "The regex in question was #{regex}"
      end
      name = self.name.to_s.gsub(/[-\[\]{}()*+?.,\\^$|#\s]/, '\\$&')
      regex = (
        if self.alias_name
          alias_name = self.alias_name.to_s.gsub(
            /[-\[\]{}()*+?.,\\^$|#\s]/,
            '\\$&'
          )
          Regexp.new(
            "^[@]?(?:#{alias_name}[:,]?|#{name}[:,]?)\\s*(?:#{pattern})",
            options
          )
        else
          Regexp.new("^[@]?#{name}[:,]?\\s*(?:#{pattern})", options)
        end
      )
      @listeners << TextListener.new(self, regex, &block)
    end

    # Adds a Listener that triggers when anyone enters the room.
    #
    # @yield [message] A Function that is called with a Response object.
    # @yieldparam message [Response]
    # @return [void]
    def enter(&block)
      @listeners << Listener.new(self,
        ->(message) { message.is_a?(EnterMessage) },
        &block)
    end

    # Adds a Listener that triggers when anyone leaves the room.
    #
    # @yield [message] A Function that is called with a Response object.
    # @yieldparam message [Response]
    # @return [void]
    def leave(&block)
      @listeners << Listener.new(self,
        ->(message) { message.is_a?(LeaveMessage) },
        &block)
    end

    # Adds a Listener that triggers when anyone changes the topic.
    #
    # @yield [message] A Function that is called with a Response object.
    # @yieldparam message [Response]
    # @return [void]
    def topic(&block)
      @listeners << Listener.new(self,
        ->(message) { message.is_a?(TopicMessage) },
        &block)
    end

    # Adds an error handler when an uncaught exception or user emitted error
    # event occurs.
    #
    # @yield [message] A Function that is called with a Response object.
    # @yieldparam message [Response]
    # @return [void]
    def error(&block)
      @error_handlers << block
    end

    # Adds a Listener that triggers when no other text matchers match.
    #
    # @yield [message] A Function that is called with a Response object.
    # @yieldparam message [Response]
    # @return [void]
    def catch_all(&block)
      listener = Listener.new(self,
        ->(message) { message.is_a?(CatchAllMessage) },
        ->(message) do
          message.message = message.message.message
          callback.call(message)
        end
      )
      @listeners << listener
    end

    # Passes the given message to any interested Listeners.
    #
    # @param message [Message] A Message instance.
    #   Listeners can flag this message as 'done' to prevent further execution.
    # @return [void]
    def receive(message)
      results = []
      @listeners.each do |listener|
        begin
          results.push(listener.call(message))
          break if message.done?
        rescue => e
          emit(:error, e, @response.new(self, message, []))
        end
      end
      if !message.is_a?(CatchAllMessage) && !results.index(true) == -1
        receive(CatchAllMessage.new(message))
      end
    end

    # Loads plugin in the given file path.
    #
    # @param plugin_path [String]
    # @return [void]
    def load_plugin(plugin_path)
      plugin_name = File.basename(plugin_path).sub('.rb', '')
      logger.debug "Loading plugin \"#{plugin_name}\""
      EvalContext.new(self).evaluate(plugin_path)
      parse_help(plugin_path)
    rescue => e
      logger.error \
      "Could not load plugin \"#{plugin_path}\": #{e.message}\n" +
        e.backtrace.join("\n")
      exit 1
    end

    # Loads every plugin in the given directory paths.
    #
    # @param plugin_paths [Array<String>]
    # @return [void]
    def load_plugins(*plugin_paths)
      plugin_paths.flatten.each do |plugin_path|
        plugin_path = File.expand_path(plugin_path)
        next unless File.directory?(plugin_path)
        logger.debug "Loading plugins from \"#{plugin_path}\""
        Dir[plugin_path + '/**/*.rb'].each do |f|
          load_plugin(f)
        end
      end
    end

    # A helper send function which delegates to the adapter's send function.
    #
    # @param user [User] A User instance.
    # @param strings [Array<String>]
    #   One or more Strings for each message to send.
    # @return [void]
    def send(user, *strings)
      adapter.send(user, *strings)
    end

    # A helper reply function which delegates to the adapter's reply function.
    #
    # @param user [User] A User instance.
    # @param strings [Array<String>]
    #   One or more Strings for each message to send.
    # @return [void]
    def reply(user, *strings)
      adapter.send(user, *strings)
    end

    # A helper send function to message a room that the robot is in.
    #
    # @param room [Symbol, String] String designating the room to message.
    # @param strings [Array<String>]
    #   One or more Strings for each message to send.
    # @return [void]
    def message_room(room, *strings)
      adapter.send(Hashie::Mash.new(room: room), *strings)
    end

    # Kick off the event loop for the adapter
    #
    # @return [void]
    def run
      emit(:running)
      adapter.run
    end

    # Gracefully shutdown the robot process
    #
    # @return [void]
    def shutdown
      adapter.close
      brain.close
    end

    private

    def load_adapter(adapter_name)
      logger.debug "Loading adapter \"#{adapter_name}\""
      @adapter = Adapters.use(adapter_name, self)
    rescue LoadError => e
      logger.error e.message
      exit 1
    end

    def invoke_error_handlers(error, message)
      @error_handlers.each do |error_handler|
        begin
          error_handler.call(error, message)
        rescue => e
          logger.error \
            "While invoking error handler: #{e.message}\n" +
            e.backtrace.join("\n")
        end
      end
    end

    def parse_help(f)
      lines = IO.readlines(f)
        .grep(/\A#/)
        .map { |l| l.sub(/\A#/, '') }
        .select { |l| l.size > 0 }
      lines.shift if lines.first =~ /coding: .+/
      current_section = nil
      lines.each do |line|
        if line =~ /(\S+):/
          current_section = $1.downcase.to_sym
        elsif current_section == :commands
          command = line.strip
          @commands << command if command.size > 0
        end
      end
    end
  end
end
