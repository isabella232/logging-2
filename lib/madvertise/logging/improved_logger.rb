require 'logger'
require 'stringio'

require 'madvertise/logging/improved_io'

module Madvertise
  module Logging

    ##
    # ImprovedLogger is an enhanced version of DaemonKits AbstractLogger class
    # with token support, buffer backend and more.
    #
    class ImprovedLogger < ImprovedIO

      # Program name prefix. Used as ident for syslog backends.
      attr_accessor :progname

      # Arbitrary token to prefix log messages with.
      attr_accessor :token

      @severities = {
        :debug   => Logger::DEBUG,
        :info    => Logger::INFO,
        :warn    => Logger::WARN,
        :error   => Logger::ERROR,
        :fatal   => Logger::FATAL,
        :unknown => Logger::UNKNOWN
      }

      @silencer = true

      class << self
        # Hash of Symbol/Fixnum pairs to map Logger levels.
        attr_reader :severities

        # Enable/disable the silencer on a global basis. Useful for debugging
        # otherwise silenced code blocks.
        attr_accessor :silencer
      end

      def initialize(logfile = nil, progname = nil)
        @progname = progname || File.basename($0)
        self.logger = logfile
      end

      # Get the backend logger.
      #
      # @return [Logger] The currently active backend logger object.
      def logger
        @logger ||= create_backend
      end

      # Set a different backend.
      #
      # @param [Symbol, String, Logger] value  The new logger backend. Either a
      #   Logger object, a String containing the logfile path or a Symbol to
      #   create a default backend for :syslog or :buffer
      # @return [Logger] The newly created backend logger object.
      def logger=(value)
        @logger.close rescue nil
        @logfile = value.is_a?(String) ? value : nil
        @backend = value.is_a?(Symbol) ? value : :logger
        @logger = value.is_a?(Logger) ? value : create_backend
      end

      # Close any connections/descriptors that may have been opened by the
      # current backend.
      def close
        logger.close rescue nil
        @logger = nil
      end

      # Retrieve the current buffer in case this instance is a buffered logger.
      #
      # @return [String] Contents of the buffer.
      def buffer
        @logfile.string if @backend == :buffer
      end

      # Get the current logging level.
      #
      # @return [Symbol] Current logging level.
      def level
        self.class.severities.invert[@logger.level]
      end

      # Set the logging level.
      #
      # @param [Symbol, Fixnum] level  New level as Symbol or Fixnum from Logger class.
      # @return [Fixnum] New level converted to Fixnum from Logger class.
      def level=(level)
        level = level.is_a?(Symbol) ? self.class.severities[level] : level
        logger.level = level
      end

      # Log a debug level message.
      def debug(msg)
        add(:debug, msg)
      end

      # Log an info level message.
      def info(msg)
        add(:info, msg)
      end

      # Log a warning level message.
      def warn(msg)
        add(:warn, msg)
      end

      # Log an error level message.
      def error(msg)
        add(:error, msg)
      end

      # Log a fatal level message.
      def fatal(msg)
        add(:fatal, msg)
      end

      # Log a message with unknown level.
      def unknown(msg)
        add(:unknown, msg)
      end

      # Log an info level message
      def <<(msg)
        add(:info, msg)
      end

      alias write <<

      # Log an exception with error level.
      #
      # @param [Exception, String] exc  The exception to log. If exc is a
      #   String no backtrace will be generated.
      def exception(exc)
        exc = "EXCEPTION: #{exc.message}: #{clean_trace(exc.backtrace)}" if exc.is_a?(::Exception)
        add(:error, exc, true)
      end

      # Save the current token and associate it with obj#object_id.
      def save_token(obj)
        if @token
          @tokens ||= {}
          @tokens[obj.object_id] = @token
        end
      end

      # Restore the token that has been associated with obj#object_id.
      def restore_token(obj)
        @tokens ||= {}
        @token = @tokens.delete(obj.object_id)
      end

      # Silence the logger for the duration of the block.
      def silence(temporary_level = :error)
        if self.class.silencer
          begin
            old_level, self.level = self.level, temporary_level
            yield self
          ensure
            self.level = old_level
          end
        else
          yield self
        end
      end

      # Remove references to the madvertise-logging gem from exception
      # backtraces.
      #
      # @private
      def clean_trace(trace)
        trace.reject do |line|
          line =~ /(gems|vendor)\/madvertise-logging/
        end
      end

      private

      # Return the first callee outside the madvertise-logging gem. Used in add
      # to figure out where in the source code a message has been produced.
      def called_from
        location = caller.detect('unknown:0') do |line|
          line.match(/(improved_logger|multi_logger)\.rb/).nil?
        end

        file, num, discard = location.split(':')
        [ File.basename(file), num ].join(':')
      end

      def add(severity, message, skip_caller = false)
        severity = self.class.severities[severity]
        message = "#{called_from}: #{message}" unless skip_caller
        message = "[#{@token}] #{message}" if @token

        logger.add(severity) { message }
      end

      def create_backend
        case @backend
        when :buffer
          create_buffering_backend
        when :syslog
          create_syslog_backend
        else
          create_standard_backend
        end
      end

      def create_buffering_backend
        @logfile = StringIO.new
        create_logger
      end

      def create_standard_backend
        begin
          FileUtils.mkdir_p(File.dirname(@logfile))
        rescue
          $stderr.puts "#{@logfile} not writable, using stderr for logging" if @logfile
          @logfile = $stderr
        end

        create_logger
      end

      def create_logger
        Logger.new(@logfile).tap do |logger|
          logger.formatter = Formatter.new
          logger.progname = progname
        end
      end

      def create_syslog_backend
        begin
          require 'syslogger'
          Syslogger.new(progname, Syslog::LOG_PID, Syslog::LOG_LOCAL1)
        rescue LoadError
          self.logger = :logger
          self.error("Couldn't load syslogger gem, reverting to standard logger")
        end
      end

      ##
      # The Formatter class is responsible for formatting log messages. The
      # default format is:
      #
      #   YYYY:MM:DD HH:MM:SS.MS daemon_name(pid) level: message
      #
      class Formatter

        @format = "%s %s(%d) [%s] %s\n"

        class << self
          # Format string for log messages.
          attr_accessor :format
        end

        # @private
        def call(severity, time, progname, msg)
          # this is so ugly because ruby 1.8 does not support %N in strftime
          time = time.strftime("%Y-%m-%d %H:%M:%S.") + sprintf('%.6f', time.usec.to_f/1000/1000)[2..-1]
          self.class.format % [time, progname, $$, severity, msg.to_s]
        end
      end

      module IOCompat
        def close_read
          nil
        end

        def close_write
          close
        end

        def closed?
          raise NotImplementedError
        end

        def sync
          @backend != :buffer
        end

        def sync=(value)
          raise NotImplementedError, "#{self} cannot change sync mode"
        end

        # ImprovedLogger is write-only
        def _raise_write_only
          raise IOError, "#{self} is a buffer-less, write-only, non-seekable stream."
        end

        [
          :bytes,
          :chars,
          :codepoints,
          :lines,
          :eof?,
          :getbyte,
          :getc,
          :gets,
          :pos,
          :pos=,
          :read,
          :readlines,
          :readpartial,
          :rewind,
          :seek,
          :ungetbyte,
          :ungetc
        ].each do |meth|
          alias_method meth, :_raise_write_only
        end
      end

      include IOCompat
    end
  end
end
