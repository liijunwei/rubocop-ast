# frozen_string_literal: true

require 'digest/sha1'

module RuboCop
  # ProcessedSource contains objects which are generated by Parser
  # and other information such as disabled lines for cops.
  # It also provides a convenient way to access source lines.
  class ProcessedSource
    STRING_SOURCE_NAME = '(string)'.freeze

    attr_reader :path, :buffer, :ast, :comments, :tokens, :diagnostics,
                :parser_error, :raw_source, :ruby_version

    def self.from_file(path, ruby_version)
      file = File.read(path, mode: 'rb')
      new(file, ruby_version, path)
    rescue Errno::ENOENT
      raise RuboCop::Error, "No such file or directory: #{path}"
    end

    def initialize(source, ruby_version, path = nil)
      # Defaults source encoding to UTF-8, regardless of the encoding it has
      # been read with, which could be non-utf8 depending on the default
      # external encoding.
      unless source.encoding == Encoding::UTF_8
        source.force_encoding(Encoding::UTF_8)
      end

      @raw_source = source
      @path = path
      @diagnostics = []
      @ruby_version = ruby_version
      @parser_error = nil

      parse(source, ruby_version)
    end

    def comment_config
      @comment_config ||= CommentConfig.new(self)
    end

    def disabled_line_ranges
      comment_config.cop_disabled_line_ranges
    end

    def ast_with_comments
      return if !ast || !comments

      @ast_with_comments ||= Parser::Source::Comment.associate(ast, comments)
    end

    # Returns the source lines, line break characters removed, excluding a
    # possible __END__ and everything that comes after.
    def lines
      @lines ||= begin
        all_lines = @buffer.source_lines
        last_token_line = tokens.any? ? tokens.last.line : all_lines.size
        result = []
        all_lines.each_with_index do |line, ix|
          break if ix >= last_token_line && line == '__END__'

          result << line
        end
        result
      end
    end

    def [](*args)
      lines[*args]
    end

    def valid_syntax?
      return false if @parser_error

      @diagnostics.none? { |d| %i[error fatal].include?(d.level) }
    end

    # Raw source checksum for tracking infinite loops.
    def checksum
      Digest::SHA1.hexdigest(@raw_source)
    end

    def each_comment
      comments.each { |comment| yield comment }
    end

    def find_comment
      comments.find { |comment| yield comment }
    end

    def each_token
      tokens.each { |token| yield token }
    end

    def find_token
      tokens.find { |token| yield token }
    end

    def file_path
      buffer.name
    end

    def blank?
      ast.nil?
    end

    def commented?(source_range)
      comment_lines.include?(source_range.line)
    end

    def comments_before_line(line)
      comments.select { |c| c.location.line <= line }
    end

    def start_with?(string)
      return false if self[0].nil?

      self[0].start_with?(string)
    end

    def preceding_line(token)
      lines[token.line - 2]
    end

    def following_line(token)
      lines[token.line]
    end

    def line_indentation(line_number)
      lines[line_number - 1]
        .match(/^(\s*)/)[1]
        .to_s
        .length
    end

    private

    def comment_lines
      @comment_lines ||= comments.map { |c| c.location.line }
    end

    def parse(source, ruby_version)
      buffer_name = @path || STRING_SOURCE_NAME
      @buffer = Parser::Source::Buffer.new(buffer_name, 1)

      begin
        @buffer.source = source
      rescue EncodingError => ex
        @parser_error = ex
        return
      end

      @ast, @comments, @tokens = tokenize(create_parser(ruby_version))
    end

    def tokenize(parser)
      begin
        ast, comments, tokens = parser.tokenize(@buffer)
        ast.complete! if ast
      rescue Parser::SyntaxError # rubocop:disable Lint/HandleExceptions
        # All errors are in diagnostics. No need to handle exception.
      end

      tokens = tokens.map { |t| Token.from_parser_token(t) } if tokens

      [ast, comments, tokens]
    end

    # rubocop:disable Metrics/MethodLength
    def parser_class(ruby_version)
      case ruby_version
      when 2.2
        require 'parser/ruby22'
        Parser::Ruby22
      when 2.3
        require 'parser/ruby23'
        Parser::Ruby23
      when 2.4
        require 'parser/ruby24'
        Parser::Ruby24
      when 2.5
        require 'parser/ruby25'
        Parser::Ruby25
      when 2.6
        require 'parser/ruby26'
        Parser::Ruby26
      else
        raise ArgumentError, "Unknown Ruby version: #{ruby_version.inspect}"
      end
    end
    # rubocop:enable Metrics/MethodLength

    def create_parser(ruby_version)
      builder = RuboCop::AST::Builder.new

      parser_class(ruby_version).new(builder).tap do |parser|
        # On JRuby there's a risk that we hang in tokenize() if we
        # don't set the all errors as fatal flag. The problem is caused by a bug
        # in Racc that is discussed in issue #93 of the whitequark/parser
        # project on GitHub.
        parser.diagnostics.all_errors_are_fatal = (RUBY_ENGINE != 'ruby')
        parser.diagnostics.ignore_warnings = false
        parser.diagnostics.consumer = lambda do |diagnostic|
          @diagnostics << diagnostic
        end
      end
    end
  end
end
