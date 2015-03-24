require 'json'
require 'bcp47'
require 'addressable/template'
require 'rdf/xsd'

##
# CSVM Metadata processor
#
# * Extracts Metadata from file or Hash definition
# * Merges multiple Metadata definitions
# * Extract Metadata from a CSV file
# * Return table-level annotations
# * Return Column-level annotations
# * Return row iterator with column information
#
# @author [Gregg Kellogg](http://greggkellogg.net/)
module RDF::Tabular
  class Metadata
    include Utils

    # Hash representation
    attr_accessor :object

    # Inheritect properties, valid for all types
    INHERITED_PROPERTIES = {
      null:               :atomic,
      lang:               :atomic,
      textDirection:      :atomic,
      separator:          :atomic,
      default:            :atomic,
      ordered:            :atomic,
      datatype:           :atomic,
      aboutUrl:           :uri_template,
      propertyUrl:        :uri_template,
      valueUrl:           :uri_template,
    }.freeze

    # Valid datatypes
    DATATYPES = {
      anyAtomicType:      RDF::XSD.anySimpleType,
      anyURI:             RDF::XSD.anyURI,
      base64Binary:       RDF::XSD.basee65Binary,
      boolean:            RDF::XSD.boolean,
      byte:               RDF::XSD.byte,
      date:               RDF::XSD.date,
      dateTime:           RDF::XSD.dateTime,
      dateTimeDuration:   RDF::XSD.dateTimeDuration,
      dateTimeStamp:      RDF::XSD.dateTimeStamp,
      decimal:            RDF::XSD.decimal,
      double:             RDF::XSD.double,
      float:              RDF::XSD.float,
      ENTITY:             RDF::XSD.ENTITY,
      gDay:               RDF::XSD.gDay,
      gMonth:             RDF::XSD.gMonth,
      gMonthDay:          RDF::XSD.gMonthDay,
      gYear:              RDF::XSD.gYear,
      gYearMonth:         RDF::XSD.gYearMonth,
      hexBinary:          RDF::XSD.hexBinary,
      int:                RDF::XSD.int,
      integer:            RDF::XSD.integer,
      lang:               RDF::XSD.language,
      language:           RDF::XSD.language,
      long:               RDF::XSD.long,
      Name:               RDF::XSD.Name,
      NCName:             RDF::XSD.NCName,
      negativeInteger:    RDF::XSD.negativeInteger,
      nonNegativeInteger: RDF::XSD.nonNegativeInteger,
      nonPositiveInteger: RDF::XSD.nonPositiveInteger,
      normalizedString:   RDF::XSD.normalizedString,
      NOTATION:           RDF::XSD.NOTATION,
      positiveInteger:    RDF::XSD.positiveInteger,
      QName:              RDF::XSD.Qname,
      short:              RDF::XSD.short,
      string:             RDF::XSD.string,
      time:               RDF::XSD.time,
      token:              RDF::XSD.token,
      unsignedByte:       RDF::XSD.unsignedByte,
      unsignedInt:        RDF::XSD.unsignedInt,
      unsignedLong:       RDF::XSD.unsignedLong,
      unsignedShort:      RDF::XSD.unsignedShort,
      yearMonthDuration:  RDF::XSD.yearMonthDuration,

      any:                RDF::XSD.anySimpleType,
      binary:             RDF::XSD.base64Binary,
      datetime:           RDF::XSD.dateTime,
      html:               RDF.HTML,
      json:               RDF::Tabular::CSVW.JSON,
      number:             RDF::XSD.double,
      xml:                RDF.XMLLiteral,
    }

    # A name is restricted according to the following RegExp.
    # @return [RegExp]
    NAME_SYNTAX = %r(\A(?:_col|[a-zA-Z0-9])[a-zA-Z0-9\._]*\z)

    # ID of this Metadata
    # @return [RDF::URI]
    attr_reader :id

    # URL of related resource
    # @return [RDF::URI]
    attr_reader :url

    # Parent of this Metadata (TableGroup for Table, ...)
    # @return [Metadata]
    attr_reader :parent

    # Filename(s) (URI) of opened metadata, if any
    # May be plural when merged
    # @return [Array<RDF::URI>] filenames
    attr_reader :filenames

    ##
    # Attempt to retrieve the file at the specified path. If it is valid metadata, create a new Metadata object from it, otherwise, an empty Metadata object
    #
    # @param [String] path
    # @param [Hash{Symbol => Object}] options
    #   see `RDF::Util::File.open_file` in RDF.rb
    def self.open(path, options = {})
      options = options.merge(
        headers: {
          'Accept' => 'application/ld+json, application/json'
        }
      )
      path = "file:" + path unless path =~ /^\w+:/
      RDF::Util::File.open_file(path, options) do |file|
        self.new(file, options.merge(base: path, filenames: path))
      end
    end

    ##
    # Return metadata for a file, based on user-specified, embedded and path-relative locations from an input file
    # @param [IO, StringIO] input
    # @param [Hash{Symbol => Object}] options
    # @option options [Metadata, Hash, String, RDF::URI] :metadata user supplied metadata, merged on top of extracted metadata. If provided as a URL, Metadata is loade from that location
    # @option options [RDF::URI] :base
    #   The Base URL to use when expanding the document. This overrides the value of `input` if it is a URL. If not specified and `input` is not an URL, the base URL defaults to the current document URL if in a browser context, or the empty string if there is no document context.
    # @return [Metadata]
    def self.for_input(input, options = {})
      base = options[:base]

      # Use user metadata
      user_metadata = case options[:metadata]
      when Metadata then options[:metadata]
      when Hash
        Metadata.new(options[:metadata], options.merge(reason: "load user metadata: #{options[:metadata].inspect}"))
      when String, RDF::URI
        Metadata.open(options[:metadata], options.merge(reason: "load user metadata: #{options[:metadata].inspect}"))
      end

      found_metadata = nil

      # If user_metadata does not describe input, get the first found from linked-, file-, and directory-specific metadata
      unless user_metadata.is_a?(Table) || user_metadata.is_a?(TableGroup) && user_metadata.for_table(base)
        # load link metadata, if available
        locs = []
        if input.respond_to?(:links) && 
          link = input.links.find_link(%w(rel describedby))
          locs << RDF::URI(base).join(link.href)
        end

        if base
          locs += [RDF::URI("#{base}-metadata.json"), RDF::URI(base).join("metadata.json")]
        end

        locs.each do |loc|
          found_metadata ||= begin
            Metadata.open(loc, options.merge(reason: "load found metadata: #{loc}"))
          rescue
            debug("for_input", options) {"failed to load found metadata #{loc}: #{$!}"}
            nil
          end
        end
      end

      # Merge user and found to get dialect description
      parse_md = if user_metadata && found_metadata
        user_metadata.merge(found_metadata)
      else
        user_metadata || found_metadata || TableGroup.new({:@context => 'http://www.w3.org/ns/csvw'}, options)
      end
      embedded_metadata = parse_md.dialect.embedded_metadata(input, options)

      # Merge user metadata with embedded metadata 
      embedded_metadata = user_metadata.merge(embedded_metadata) if user_metadata

      # Merge embedded metadata with found
      found_metadata ? embedded_metadata.merge(found_metadata) : embedded_metadata
    end

    ##
    # @private
    def self.new(input, options = {})
      # Triveal case
      return input if input.is_a?(Metadata)

      object = case input
      when Hash then input
      when IO, StringIO then ::JSON.parse(input.read)
      else ::JSON.parse(input.to_s)
      end

      unless options[:parent]
        # Add context, if not set (which it should be)
        object['@context'] ||= options.delete(:@context) || options[:context] || 'http://www.w3.org/ns/csvw'
      end

      klass = case
        when !self.equal?(RDF::Tabular::Metadata)
          self # subclasses can be directly constructed without type dispatch
        else
          type = if options[:type]
            type = options[:type].to_sym
            raise Error, "If provided, type must be one of :TableGroup, :Table, :Transformation, :Schema, :Column, :Dialect]" unless
              [:TableGroup, :Table, :Transformation, :Schema, :Column, :Dialect].include?(type)
            type
          end

          # Figure out type by @type
          type ||= object['@type']

          # Figure out type by site
          object_keys = object.keys.map(&:to_s)
          type ||= case
          when %w(resources).any? {|k| object_keys.include?(k)} then :TableGroup
          when %w(dialect tableSchema transformations).any? {|k| object_keys.include?(k)} then :Table
          when %w(targetFormat scriptFormat source).any? {|k| object_keys.include?(k)} then :Transformation
          when %w(columns primaryKey foreignKeys urlTemplate).any? {|k| object_keys.include?(k)} then :Schema
          when %w(name required).any? {|k| object_keys.include?(k)} then :Column
          when %w(commentPrefix delimiter doubleQuote encoding header headerColumnCount headerRowCount).any? {|k| object_keys.include?(k)} then :Dialect
          when %w(lineTerminator quoteChar skipBlankRows skipColumns skipInitialSpace skipRows trim).any? {|k| object_keys.include?(k)} then :Dialect
          end

          case type.to_s.to_sym
          when :TableGroup then RDF::Tabular::TableGroup
          when :Table then RDF::Tabular::Table
          when :Transformation then RDF::Tabular::Transformation
          when :Schema then RDF::Tabular::Schema
          when :Column then RDF::Tabular::Column
          when :Dialect then RDF::Tabular::Dialect
          else
            raise Error, "Unkown metadata type: #{type.inspect}"
          end
        end

      md = klass.allocate
      md.send(:initialize, object, options)
      md
    end

    ##
    # Create Metadata from IO, Hash or String
    #
    # @param [Metadata, Hash, #read] input
    # @param [Hash{Symbol => Object}] options
    # @option options [:TableGroup, :Table, :Transformation, :Schema, :Column, :Dialect] :type
    #   Type of schema, if not set, intuited from properties
    # @option options [JSON::LD::Context] context
    #   Context used for this metadata. Taken from input if not provided
    # @option options [RDF::URI] :base
    #   The Base URL to use when expanding the document. This overrides the value of `input` if it is a URL. If not specified and `input` is not an URL, the base URL defaults to the current document URL if in a browser context, or the empty string if there is no document context.
    # @option options [Boolean] :validate
    #   Validate metadata, and raise error if invalid
    # @raise [Error]
    # @return [Metadata]
    def initialize(input, options = {})
      @options = options.dup

      # Get context from input
      @context = ::JSON::LD::Context.new.parse(input['@context']) if input.has_key?('@context')
      reason = @options.delete(:reason)

      @options[:base] ||= @context.base if @context
      @options[:base] ||= input.base_uri if input.respond_to?(:base_uri)
      @options[:base] ||= input.filename if input.respond_to?(:filename)
      @options[:base] = RDF::URI(@options[:base])

      @context.base = @options[:base] if @context

      @options[:depth] ||= 0
      @filenames = Array(@options[:filenames]).map {|fn| RDF::URI(fn)} if @options[:filenames]
      @properties = self.class.const_get(:PROPERTIES)
      @required = self.class.const_get(:REQUIRED)

      @object = {}

      # Parent of this Metadata, if any
      @parent = @options[:parent]

      depth do
        # Input was parsed in .new
        # Metadata is object with symbolic keys
        input.each do |key, value|
          key = key.to_sym
          case key
          when :columns
            # An array of template specifications that provide mechanisms to transform the tabular data into other formats
            object[key] = if value.is_a?(Array) && value.all? {|v| v.is_a?(Hash)}
              number = 0
              value.map do |v|
                number += 1
                Column.new(v, @options.merge(table: (parent if parent.is_a?(Table)), parent: self, context: nil, number: number))
              end
            else
              # Invalid, but preserve value
              value
            end
          when :datatype
            # If in object form, normalize keys to symbols
            object[key] = case value
            when Hash
              value.inject({}) {|memo, (k,v)| memo[k.to_sym] = v; memo}
            else
              value
            end
          when :dialect
            # If provided, dialect provides hints to processors about how to parse the referenced file to create a tabular data model.
            object[key] = case value
            when String then Dialect.open(base.join(value), @options.merge(parent: self, context: nil))
            when Hash   then Dialect.new(value, @options.merge(parent: self, context: nil))
            else
              # Invalid, but preserve value
              value
            end
            @type ||= :Table
          when :resources
            # An array of table descriptions for the tables in the group.
            object[key] = if value.is_a?(Array) && value.all? {|v| v.is_a?(Hash)}
              value.map {|v| Table.new(v, @options.merge(parent: self, context: nil))}
            else
              # Invalid, but preserve value
              value
            end
          when :tableSchema
            # An object property that provides a schema description as described in section 3.8 Schemas, for all the tables in the group. This may be provided as an embedded object within the JSON metadata or as a URL reference to a separate JSON schema document
            # SPEC SUGGESTION: when loading a remote schema, assign @id from it's location if not already set
            object[key] = case value
            when String
              link = base.join(value).to_s
              s = Schema.open(link, @options.merge(parent: self, context: nil))
              s[:@id] ||= link
              s
            when Hash   then Schema.new(value, @options.merge(parent: self, context: nil))
            else
              # Invalid, but preserve value
              value
            end
          when :transformations
            # An array of template specifications that provide mechanisms to transform the tabular data into other formats
            object[key] = if value.is_a?(Array) && value.all? {|v| v.is_a?(Hash)}
              value.map {|v| Transformation.new(v, @options.merge(parent: self, context: nil))}
            else
              # Invalid, but preserve value
              value
            end
          when :url
            # URL of CSV relative to metadata
            object[:url] = value
            @url = base.join(value)
            @context.base = @url if @context # Use as base for expanding IRIs
          when :@id
            # metadata identifier
            object[:@id] = value
            @id = base.join(value)
          else
            if @properties.has_key?(key)
              self.send("#{key}=".to_sym, value)
            else
              object[key] = value
            end
          end
        end
      end

      # Set type from @type, if present and not otherwise defined
      @type ||= object[:@type].to_sym if object[:@type]
      if reason
        debug("md#initialize") {reason}
        debug("md#initialize") {"filenames: #{filenames}"}
        debug("md#initialize") {"#{inspect}, parent: #{!@parent.nil?}, context: #{!@context.nil?}"} unless is_a?(Dialect)
      end

      validate! if options[:validate]
    end

    # Setters
    INHERITED_PROPERTIES.keys.each do |a|
      define_method("#{a}=".to_sym) do |value|
        object[a] = value.to_s =~ /^\d+/ ? value.to_i : value
      end
    end

    # Context used for this metadata. Use parent's if not defined on self.
    # @return [JSON::LD::Context]
    def context
      @context || (parent.context if parent)
    end

    # Treat `dialect` similar to an inherited property, but merge together values from Table and TableGroup
    # @return [Dialect]
    def dialect
      @dialect ||= case
      when object[:dialect] then object[:dialect]
      when parent then parent.dialect
      when is_a?(Table) || is_a?(TableGroup)
        d = Dialect.new({}, @options.merge(parent: self, context: nil))
        self.dialect = d unless self.parent
        d
      else
        raise Error, "Can't access dialect from #{self.class} without a parent"
      end
    end

    # Set new dialect
    # @return [Dialect]
    def dialect=(value)
      # Clear cached dialect information from children
      object.values.each do |v|
        case v
        when Metadata then v.object.delete(:dialect)
        when Array then v.each {|vv| vv.object.delete(:dialect) if vv.is_a?(Metadata)}
        end
      end

      if value.is_a?(Hash)
        @dialect = object[:dialect] = Dialect.new(value)
      elsif value
        # Remember invalid dialect for validation purposes
        object[:dialect] = value
      else
        object.delete(:dialect)
        @dialect = nil
      end
    end

    # Type of this Metadata
    # @return [:TableGroup, :Table, :Transformation, :Schema, :Column]
    def type; self.class.name.split('::').last.to_sym; end

    # Base URL of metadata
    # @return [RDF::URI]
    def base; @options[:base]; end

    ##
    # Do we have valid metadata?
    def valid?
      validate!
      true
    rescue
      false
    end

    ##
    # Validation errors
    # @return [Array<String>]
    def errors
      validate! && []
    rescue Error => e
      e.message.split("\n")
    end

    ##
    # Validate metadata, raising an error containing all errors detected during validation
    # @raise [Error] Raise error if metadata has any unexpected properties
    # @return [self]
    def validate!
      expected_props, required_props = @properties.keys, @required
      errors = []

      unless is_a?(Dialect) || is_a?(Transformation)
        expected_props = expected_props + INHERITED_PROPERTIES.keys
      end

      # It has only expected properties (exclude metadata)
      check_keys = object.keys - [:"@id", :"@context"]
      check_keys = check_keys.reject {|k| k.to_s.include?(':')} unless is_a?(Dialect)
      errors << "#{type} has unexpected keys: #{(check_keys - expected_props).map(&:to_s)}" unless check_keys.all? {|k| expected_props.include?(k)}

      # It has required properties
      errors << "#{type} missing required keys: #{(required_props & check_keys).map(&:to_s)}"  unless (required_props & check_keys) == required_props

      # Every property is valid
      object.keys.each do |key|
        value = object[key]
        case key
        when :aboutUrl, :datatype, :default, :lang, :null, :ordered, :propertyUrl, :separator, :textDirection, :valueUrl
          valid_inherited_property?(key, value) {|m| errors << m}
        when :columns
          if value.is_a?(Array) && value.all? {|v| v.is_a?(Column)}
            value.each do |v|
              begin
                v.validate!
              rescue Error => e
                errors << e.message
              end
            end
            column_names = value.map(&:name)
            errors << "#{type} has invalid property '#{key}': must have unique names: #{column_names.inspect}" unless column_names.uniq == column_names
          else
            errors << "#{type} has invalid property '#{key}': expected array of Columns"
          end
        when :commentPrefix, :delimiter, :quoteChar
          unless value.is_a?(String) && value.length == 1
            errors << "#{type} has invalid property '#{key}': #{value.inspect}, expected a single character string"
          end
        when :format, :lineTerminator, :uriTemplate
          unless value.is_a?(String)
            errors << "#{type} has invalid property '#{key}': #{value.inspect}, expected a string"
          end
        when :dialect
          unless value.is_a?(Dialect)
            errors << "#{type} has invalid property '#{key}': expected a Dialect Description"
          end
          begin
            value.validate! if value
          rescue Error => e
            errors << e.message
          end
        when :doubleQuote, :header, :required, :skipInitialSpace, :skipBlankRows, :suppressOutput, :virtual
          unless value.is_a?(TrueClass) || value.is_a?(FalseClass)
            errors << "#{type} has invalid property '#{key}': #{value}, expected boolean true or false"
          end
        when :encoding
          unless Encoding.find(value)
            errors << "#{type} has invalid property '#{key}': #{value.inspect}, expected a valid encoding"
          end
        when :foreignKeys
          # An array of foreign key definitions that define how the values from specified columns within this table link to rows within this table or other tables. A foreign key definition is a JSON object with the properties:
          value.is_a?(Array) && value.each do |fk|
            if fk.is_a?(Hash)
              columns, reference = fk['columns'], fk['reference']
              errors << "#{type} has invalid property '#{key}': missing columns and reference" unless columns && reference
              errors << "#{type} has invalid property '#{key}': has extra entries #{fk.keys.inspect}" unless fk.keys.length == 2

              # Verify that columns exist in this schema
              Array(columns).each do |k|
                errors << "#{type} has invalid property '#{key}': column reference not found #{k}" unless self.columns.any? {|c| c.name == k}
              end

              if reference.is_a?(Hash)
                ref_cols = reference['columns']
                schema = if reference.has_key?('resource')
                  if reference.has_key?('tableSchema')
                    errors << "#{type} has invalid property '#{key}': reference has a tableSchema: #{reference.inspect}" 
                  end
                  # resource is the URL of a Table in the TableGroup
                  ref = base.join(reference['resource']).to_s
                  table = root.is_a?(TableGroup) && root.resources.detect {|t| t.url == ref}
                  errors << "#{type} has invalid property '#{key}': table referenced by #{ref} not found" unless table
                  table.tableSchema if table
                elsif reference.has_key?('tableSchema')
                  # resource is the @id of a Schema in the TableGroup
                  ref = base.join(reference['tableSchema']).to_s
                  tables = root.is_a?(TableGroup) ? root.resources.detect {|t| t.tableSchema[:@id] == ref} : []
                  case tables.length
                  when 0
                    errors << "#{type} has invalid property '#{key}': schema referenced by #{ref} not found"
                    nil
                  when 1
                    tables.first.tableSchema
                  else
                    errors << "#{type} has invalid property '#{key}': multiple schemas found from #{ref}"
                    nil
                  end
                end

                if schema
                  # ref_cols must exist in schema
                  Array(ref_cols).each do |k|
                    errors << "#{type} has invalid property '#{key}': column reference not found #{k}" unless schema.columns.any? {|c| c.name == k}
                  end
                end
              else
                errors << "#{type} has invalid property '#{key}': reference is not an object #{reference.inspect}"
              end
            else
              errors << "#{type} has invalid property '#{key}': reference must be an object: #{reference.inspect}" 
            end
          end
        when :headerColumnCount, :headerRowCount, :skipColumns, :skipRows
          unless value.is_a?(Numeric) && value.integer? && value > 0
            errors << "#{type} has invalid property '#{key}': #{value.inspect} must be a positive integer"
          end
        when :length, :minLength, :maxLength
          unless value.is_a?(Numeric) && value.integer? && value > 0
            errors << "#{type} has invalid property '#{key}': #{value.inspect}, expected a positive integer"
          end
          unless key == :length || value != object[:length]
            # Applications must raise an error if length, maxLength or minLength are specified and the cell value is not a list (ie separator is not specified), a string or one of its subtypes, or a binary value.
            errors << "#{type} has invalid property '#{key}': Use of both length and #{key} requires they be equal"
          end
        when :minimum, :maximum, :minInclusive, :maxInclusive, :minExclusive, :maxExclusive
          unless value.is_a?(Numeric) ||
            RDF::Literal::Date.new(value.to_s).valid? ||
            RDF::Literal::Time.new(value.to_s).valid? ||
            RDF::Literal::DateTime.new(value.to_s).valid?
            errors << "#{type} has invalid property '#{key}': #{value}, expected numeric or valid date/time"
          end
        when :name
          unless value.is_a?(String) && name.match(NAME_SYNTAX)
            errors << "#{type} has invalid property '#{key}': #{value}, expected proper name format"
          end
        when :notes
          unless value.is_a?(Hash) || value.is_a?(Array)
            errors << "#{type} has invalid property '#{key}': #{value}, Object or Array"
          end
          begin
            normalize_jsonld(key, value)
          rescue Error => e
            errors << "#{type} has invalid content '#{key}': #{e.message}"
          end
        when :primaryKey
          # A column reference property that holds either a single reference to a column description object or an array of references.
          Array(value).each do |k|
            errors << "#{type} has invalid property '#{key}': column reference not found #{k}" unless self.columns.any? {|c| c.name == k}
          end
        when :resources
          if value.is_a?(Array) && value.all? {|v| v.is_a?(Table)}
            value.each do |t|
              begin
                t.validate!
              rescue Error => e
                errors << e.message
              end
            end
          else
            errors << "#{type} has invalid property '#{key}': expected array of Tables"
          end
        when :scriptFormat, :targetFormat
          unless RDF::URI(value).valid?
            errors << "#{type} has invalid property '#{key}': #{value.inspect}, expected valid absolute URL"
          end
        when :source
          unless %w(json rdf).include?(value) || value.nil?
            errors << "#{type} has invalid property '#{key}': #{value.inspect}, expected json or rdf"
          end
        when :tableDirection
          unless %w(rtl ltr default).include?(value)
            errors << "#{type} has invalid property '#{key}': #{value.inspect}, expected rtl, ltr, or default"
          end
        when :tableSchema
          if value.is_a?(Schema)
            begin
              value.validate!
            rescue Error => e
              errors << e.message
            end
          else
            errors << "#{type} has invalid property '#{key}': expected Schema"
          end
        when :transformations
          if value.is_a?(Array) && value.all? {|v| v.is_a?(Transformation)}
            value.each do |t|
              begin
                t.validate!
              rescue Error => e
                errors << e.message
              end
            end
          else
            errors << "#{type} has invalid property '#{key}': expected array of Transformations"
          end
        when :title
          valid_natural_language_property?(:title, value) {|m| errors << m}
        when :trim
          unless value.is_a?(TrueClass) || value.is_a?(FalseClass)
            errors << "#{type} has invalid property '#{key}': #{value}, expected boolean true or false"
          end
        when :url
          unless @url.valid?
            errors << "#{type} has invalid property '#{key}': #{value.inspect}, expected valid absolute URL"
          end
        when :@id, :@context
          # Skip these
        when :@type
          unless value.to_sym == type
            errors << "#{type} has invalid property '#{key}': #{value.inspect}, expected #{type}"
          end
        when ->(k) {key.to_s.include?(':')}
          begin
            normalize_jsonld(key, value)
          rescue Error => e
            errors << "#{type} has invalid content '#{key}': #{e.message}"
          end
        else
          errors << "#{type} has invalid property '#{key}': unsupported property"
        end
      end

      raise Error, errors.join("\n") unless errors.empty?
      self
    end

    ##
    # Determine if a natural language property is valid
    # @param [String, Array<String>, Hash{String => String}] value
    # @yield message error message
    # @return [Boolean]
    def valid_natural_language_property?(key, value)
      unless value.is_a?(Hash) && value.all? {|k, v| Array(v).all? {|vv| vv.is_a?(String)}}
        yield "#{type} has invalid property '#{key}': #{value.inspect}, expected a valid natural language property" if block_given?
        false
      end
    end

    ##
    # Determine if an inherited property is valid
    # @param [String, Array<String>, Hash{String => String}] value
    # @yield message error message
    # @return [Boolean]
    def valid_inherited_property?(key, value)
      pv = parent.send(key) if parent
      error = case key
      when :aboutUrl, :default, :propertyUrl, :valueUrl
        "string" unless value.is_a?(String)
      when :datatype
        # Normalization usually redundant
        dt = normalize_datatype(value)
        # FIXME: support arrays of datatypes?
        "valid datatype" unless DATATYPES.keys.map(&:to_s).include?(dt[:base]) || RDF::URI(dt[:base]).absolute?
      when :lang
        "valid BCP47 language tag" unless BCP47::Language.identify(value.to_s)
      when :null
        # To be valid, it must be a string or array, and must be compatible with any inherited value through being a subset
        "string or array of strings" unless !value.is_a?(Hash) && Array(value).all? {|v| v.is_a?(String)}
      when :ordered
        "boolean" unless value.is_a?(TrueClass) || value.is_a?(FalseClass)
      when :separator
        "single character" unless value.is_a?(String) && value.length == 1
      when :textDirection
        # A value for this property is compatible with an inherited value only if they are identical.
        "rtl or ltr" unless %(rtl ltr).include?(value)
      end ||

      case key
        # Compatibility
      when :aboutUrl, :propertyUrl, :valueUrl
        # No restrictions
      when :default, :ordered, :separator, :textDirection
        "same as that defined on parent" if pv && pv != value
      when :datatype
        if pv
          # Normalization usually redundant
          dt = normalize_datatype(value)
          pvdt = normalize_datatype(pv)
          vl = RDF::Literal.new("", datatype: DATATYPES[dt[:base].to_sym])
          pvvl = RDF::Literal.new("", datatype: DATATYPES[pvdt[:base].to_sym])
          # must be a subclass of some type defined on parent
          "compatible datatype of that defined on parent" unless vl.is_a?(pvvl.class)
        end
      when :lang
        "lang expected to restrict #{pv}" if pv && !value.start_with?(pv)
      when :null
        "subset of that defined on parent" if pv && (Array(value) & Array(pv)) != Array(value)
      end

      if error
        yield "#{type} has invalid property '#{key}' ('#{value}'): expected #{error}"
        false
      else
        true
      end
    end

    ##
    # Yield each data row from the input file
    #
    # @param [:read] input
    # @yield [Row]
    def each_row(input)
      csv = ::CSV.new(input, csv_options)
      # Skip skipRows and headerRowCount
      number, skipped = 0, (dialect.skipRows.to_i + dialect.headerRowCount)
      (1..skipped).each {csv.shift}
      csv.each do |data|
        number += 1
        yield(Row.new(data, self, number, number + skipped))
      end
    end

    ##
    # Return JSON-friendly or yield RDF for common properties
    #
    # @overload common_properties(subject, property, value, &block)
    #   Yield RDF statements
    #   @param [RDF::Resource] subject
    #   @param [String] property
    #   @param [String, Hash{String => Object}, Array<String, Hash{String => Object}>] value
    #   @yield property, value
    #   @yieldparam [String] property as a PName or URL
    #   @yieldparam [RDF::Statement] statement
    #
    # @overload common_properties(subject, property, value)
    #   Return value with expanded values and node references flattened
    #   @return [String, Hash{String => Object}, Array<String, Hash{String => Object}>] simply extracted from metadata
    def common_properties(subject, property, value, &block)
      if block_given?
        property = context.expand_iri(property.to_s, vocab: true) unless property.is_a?(RDF::URI)
        case value
        when Array
          value.each {|v| common_properties(subject, property, v, &block)}
        when Hash
          if value['@value']
            dt = RDF::URI(context.expand_iri(value['@type'], vocab: true)) if value['@type']
            lit = RDF::Literal(value['@value'], language: value['@language'], datatype: dt)
            block.call(RDF::Statement.new(subject, property, lit))
          else
            # value MUST be a node object, establish a new subject from `@id`
            s2 = value.has_key?('@id') ? context.expand_iri(value['@id']) : RDF::Node.new

            # Generate a triple
            block.call(RDF::Statement.new(subject, property, s2))

            # Generate types
            Array(value['@type']).each do |t|
              block.call(RDF::Statement.new(s2, RDF.type, context.expand_iri(t, vocab: true)))
            end

            # Generate triples for all other properties
            value.each do |prop, val|
              next if prop.to_s.start_with?('@')
              common_properties(s2, prop, val, &block)
            end
          end
        else
          # Value is a primitive JSON value
          lit = RDF::Literal(value)
          block.call(RDF::Statement.new(subject, property, RDF::Literal(value)))
        end
      else
        case value
        when Array
          value.map {|v| common_properties(subject, property, v)}
        when Hash
          if value['@value']
            value['@value']
          elsif value.keys == %w(@id) && value['@id']
            value['@id']
          else
            nv = {}
            value.each do |k, v|
              case k.to_s
              when '@id' then nv[k.to_s] = context.expand_iri(v['@id']).to_s
              when '@type' then nv[k.to_s] = v
              else nv[k.to_s] = common_properties(nil, k, v)
              end
            end
            nv
          end
        else
          value
        end
      end
    end

    # Does the Metadata have any common properties?
    # @return [Boolean]
    def has_annotations?
      object.keys.any? {|k| k.to_s.include?(':')}
    end

    # Merge metadata into this a copy of this metadata
    # @param [Array<Metadata>] metadata
    # @return [Metadata]
    def merge(*metadata)
      return self if metadata.empty?
      # If the top-level object of any of the metadata files are table descriptions, these are treated as if they were table group descriptions containing a single table description (ie having a single resource property whose value is the same as the original table description).
      this = case self
      when TableGroup then self.dup
      when Table
        if self.is_a?(Table) && self.parent
          self.parent
        else
          content = {"@type" => "TableGroup", "resources" => [self]}
          content['@context'] = object.delete(:@context) if object[:@context]
          ctx = @context
          self.remove_instance_variable(:@context) if self.instance_variables.include?(:@context)
          tg = TableGroup.new(content, filenames: @filenames, base: base)
          @parent = tg  # Link from parent
          tg
        end
      else self.dup
      end

      # Merge all passed metadata into this
      merged = metadata.reduce(this) do |memo, md|
        md = case md
        when TableGroup then md
        when Table
          if md.parent
            md.parent
          else
            content = {"@type" => "TableGroup", "resources" => [md]}
            ctx = md.context
            content['@context'] = md.object.delete(:@context) if md.object[:@context]
            md.remove_instance_variable(:@context) if md.instance_variables.include?(:@context) 
            tg = TableGroup.new(content, filenames: md.filenames, base: md.base)
            md.instance_variable_set(:@parent, tg)  # Link from parent
            tg
          end
        else
          md
        end

        raise "Can't merge #{memo.class} with #{md.class}" unless memo.class == md.class

        memo.merge!(md)
      end

      # Set @context of merged
      merged[:@context] = 'http://www.w3.org/ns/csvw'
      merged
    end

    # Merge metadata into self
    def merge!(metadata)
      raise "Merging non-equivalent metadata types: #{self.class} vs #{metadata.class}" unless self.class == metadata.class

      depth do
        # Merge filenames
        if @filenames || metadata.filenames
          @filenames = Array(@filenames) | Array(metadata.filenames)
        end

        # Normalize A (this) and B (metadata) values into normal form
        self.normalize!
        metadata = metadata.dup.normalize!

        @dialect = nil  # So that it is re-built when needed
        # Merge each property from metadata into self
        metadata.each do |key, value|
          case @properties[key]
          when :array
            # If the property is an array property, the way in which values are merged depends on the property; see the relevant property for this definition.
            object[key] = case object[key]
            when nil then []
            when Hash then [object[key]]  # Shouldn't happen if well formed
            else object[key]
            end

            value = [value] if value.is_a?(Hash)
            case key
            when :notes
              # If the property is notes, the result is an array containing values from A followed by values from B.
              a = object[key].is_a?(Array) ? object[key] : [object[key]].compact
              b = value.is_a?(Array) ? value : [value]
              object[key] = a + b
            when :resources
              # When an array of table descriptions B is imported into an original array of table descriptions A, each table description within B is combined into the original array A by:
              value.each do |t|
                if ta = object[key].detect {|e| e.url == t.url}
                  # if there is a table description with the same url in A, the table description from B is imported into the matching table description in A
                  ta.merge!(t)
                else
                  # otherwise, the table description from B is appended to the array of table descriptions A
                  t = t.dup
                  t.instance_variable_set(:@parent, self)
                  object[key] << t
                end
              end
            when :transformations
              # SPEC CONFUSION: differing transformations with same @id?
              # When an array of template specifications B is imported into an original array of template specifications A, each template specification within B is combined into the original array A by:
              value.each do |t|
                if ta = object[key].detect {|e| e.targetFormat == t.targetFormat && e.scriptFormat == t.scriptFormat}
                  # if there is a template specification with the same targetFormat and scriptFormat in A, the template specification from B is imported into the matching template specification in A
                  ta.merge!(t)
                else
                  # otherwise, the template specification from B is appended to the array of template specifications A
                  t = t.dup
                  t.instance_variable_set(:@parent, self) if self
                  object[key] << t
                end
              end
            when :columns
              # When an array of column descriptions B is imported into an original array of column descriptions A, each column description within B is combined into the original array A by:
              Array(value).each_with_index do |t, index|
                ta = object[key][index]
                if ta && ta[:name] && ta[:name] == t[:name] 
                  debug("merge!: columns") {"index: #{index}, name=#{t[:name] }"}
                  # if there is a column description at the same index within A and that column description has the same name, the column description from B is imported into the matching column description in A
                  ta.merge!(t)
                elsif ta && ta[:title] && t[:title] && (
                  ta[:title].any? {|lang, values| !(Array(t[:title][lang]) & values).empty?} ||
                  !(Array(ta[:title]['und']) & t[:title].values.flatten.compact).empty? ||
                  !(Array(t[:title]['und']) & ta[:title].values.flatten.compact).empty?)
                  debug("merge!: columns") {"index: #{index}, title=#{t.title}"}
                  # otherwise, if there is a column description at the same index within A with a title that is also a title in A, considering the language of each title where und matches a value in any language, the column description from B is imported into the matching column description in A.
                  ta.merge!(t)
                elsif ta.nil? && t.virtual
                  debug("merge!: columns") {"index: #{index}, virtual"}
                  # otherwise, if at a given index there is no column description within A, but there is a column description within B.
                  t = t.dup
                  t.instance_variable_set(:@parent, self) if self
                  object[key][index] = t
                else
                  debug("merge!: columns") {"index: #{index}, ignore"}
                  raise Error, "Columns at same index don't match: #{ta.to_json} vs. #{t.to_json}"
                end
              end
              # The number of non-virtual columns in A and B MUST be the same
              nA = object[key].reject(&:virtual).length
              nB = Array(value).reject(&:virtual).length
              raise Error, "Columns must have the same number of non-virtual columns" unless nA == nB
            when :foreignKeys
              # When an array of foreign key definitions B is imported into an original array of foreign key definitions A, each foreign key definition within B which does not appear within A is appended to the original array A.
              # SPEC CONFUSION: If definitions vary only a little, they should probably be merged (e.g. common properties).
              object[key] = object[key] + (metadata[key] - object[key])
            end
          when :object
            case key
            when :notes
              # If the property accepts arrays, the result is an array of objects or strings: those from A followed by those from B that were not already a value in A.
              a = object[key] || []
              object[key] = (a + value).uniq
            else
              # if the property only accepts single objects
              if object[key].is_a?(String) || value.is_a?(String)
                # if the value of the property in A is a string or the value from B is a string then the value from A overrides that from B
                object[key] ||= value
              elsif object[key].is_a?(Metadata)
                # otherwise (if both values as objects) the objects are merged as described here
                object[key].merge!(value)
              elsif object[key].is_a?(Hash)
                # otherwise (if both values as objects) the objects are merged as described here
                object[key].merge!(value)
              else
                value = value.dup
                value.instance_variable_set(:@parent, self) if self
                object[key] = value
              end
            end
          when :natural_language
            # If the property is a natural language property, the result is an object whose properties are language codes and where the values of those properties are arrays. The suitable language code for the values is either explicit within the existing value or determined through the default language in the metadata document; if it can't be determined the language code und should be used. The arrays should provide the values from A followed by those from B that were not already a value in A.
            a = object[key] || {}
            b = value
            debug("merge!: natural_language") {
              "A: #{a.inspect}, B: #{b.inspect}"
            }
            b.each do |k, v|
              a[k] = Array(a[k]) + (Array(b[k]) - Array(a[k]))
            end
            # eliminate titles with no language where the same string exists with a language
            if a.has_key?("und")
              a["und"] = a["und"].reject do |v|
                a.any? {|lang, values| lang != 'und' && values.include?(v)}
              end
              a.delete("und") if a["und"].empty?
            end
            object[key] = a
          when ->(k) {key == :@id}
            object[key] ||= value
            @id ||= metadata.id
          else
            # Otherwise, the value from A overrides that from B
            object[key] ||= value
          end
        end
      end

      debug("merge!") {self.inspect}
      self
    end

    def inspect
      self.class.name + object.inspect
    end

    # Proxy to @object
    def [](key); object[key]; end
    def []=(key, value); object[key] = value; end
    def each(&block); object.each(&block); end
    def ==(other)
      object == (other.is_a?(Hash) ? other : other.object)
    end
    def to_json(args=nil); object.to_json(args); end

    ##
    # Normalize object
    # @raise [Error]
    # @return [self]
    def normalize!
      self.each do |key, value|
        self[key] = case @properties[key] || INHERITED_PROPERTIES[key]
        when ->(k) {key.to_s.include?(':') || key == :notes}
          normalize_jsonld(key, value)
        when ->(k) {key.to_s == '@context'}
          "http://www.w3.org/ns/csvw"
        when :link
          base.join(value).to_s
        when :array
          value = [value] unless value.is_a?(Array)
          value.map {|v| v.is_a?(Metadata) ? v.normalize! : v} # due to foreign keys
        when :object
          case key
          when String
            # Load referenced JSON document
            # (This is done when objects are loaded in this implementation)
            raise "unexpected String value of property '#{key}': #{value}"
          else value
          end
        when :natural_language
          value.is_a?(Hash) ? value : {(context.default_language || 'und') => Array(value)}
        when :atomic
          # If the property is an atomic property accepting strings or objects, normalize to the object form as described for that property.
          case key
          when :doubleQuote, :header, :ordered, :required, :skipBlankRows, :skipInitialSpace,
               :suppressOutput, :virtual
            %w(true 1).include?(value.to_s.downcase)
          when :skipRows, :headerRowCount, :skipColumns, :headerColumnCount
            value.to_i
          when :datatype then normalize_datatype(value)
          else                value
          end
        else
          value
        end
      end
      self
    end

    ##
    # Normalize datatype to Object/Hash representation
    # @param [String, Hash{Symbol => String}] value
    # @return [Hash{Symbol => String}]
    def normalize_datatype(value)
      # Normalize datatype to array of object form
      value = {base: value} unless value.is_a?(Hash)
      # Create a new representation using symbols and transformed values
      nv = {}
      value.each do |kk, vv|
        case kk.to_sym
        when :base, :decimalChar, :format, :groupChar, :pattern then nv[kk.to_sym] = vv
        when :length, :minLength, :maxLength, :minimum, :maximum,
          :minInclusive, :maxInclusive, :minExclusive, :maxExclusive
          nv[kk.to_sym] = vv.to_i
        end
      end
      nv[:base] ||= 'string'
      nv
    end

    ##
    # Normalize JSON-LD
    #
    # Also, raise error if invalid JSON-LD dialect is detected
    #
    # @param [Symbol, String] property
    # @param [String, Hash{String => Object}, Array<String, Hash{String => Object}>] value
    # @return [String, Hash{String => Object}, Array<String, Hash{String => Object}>]
    def normalize_jsonld(property, value)
      case value
      when Array
        value.map {|v| normalize_jsonld(property, v)}
      when String
        ev = {'@value' => value}
        ev['@language'] = context.default_language if context.default_language
        ev
      when Hash
        if value['@value']
          if !(value.keys.sort - %w(@value @type @language)).empty?
            raise Error, "Value object may not contain keys other than @value, @type, or @language: #{value.to_json}"
          elsif (value.keys.sort & %w(@language @type)) == %w(@language @type)
            raise Error, "Value object may not contain both @type and @language: #{value.to_json}"
          elsif value['@language'] && !BCP47::Language.identify(value['@language'])
            raise Error, "Value object with @language must use valid language: #{value.to_json}"
          elsif value['@type'] && !context.expand_iri(value['@type'], vocab: true).absolute?
            raise Error, "Value object with @type must defined type: #{value.to_json}"
          end
          value
        else
          nv = {}
          value.each do |k, v|
            case k
            when "@id"
              nv[k] = context.expand_iri(v, documentRelative: true).to_s
              raise Error, "Invalid use of explicit BNode on @id" if nv[k].start_with?('_:')
            when "@type"
              Array(v).each do |vv|
                # Validate that all type values transform to absolute IRIs
                resource = context.expand_iri(vv, vocab: true)
                raise Error, "Invalid type #{vv} in JSON-LD context" unless resource.uri? && resource.absolute?
              end
              nv[k] = v
            when /^(@|_:)/
              raise Error, "Invalid use of #{k} in JSON-LD content"
            else
              nv[k] = normalize_jsonld(k, v)
            end
          end
          nv
        end
      else
        value
      end
    end
  protected

    # When setting a natural language property, always put in language-map form
    # @param [Symbol] prop
    # @param [Hash{String => String, Array<String>}, Array<String>, String] value
    # @return [Hash{String => Array<String>}]
    def set_nl(prop, value)
      object[prop] = case value
      when String then {(context.default_language || 'und') => [value]}
      when Array then {(context.default_language || 'und') => value}
      else value
      end
    end

    def inherited_property_value(method)
      # Inherited properties
      object.fetch(method.to_sym) do
        parent.send(method) if parent
      end
    end

    ##
    # Get the root metadata object
    # @return [TableGroup, Table]
    def root
      self.parent ? self.parent.root : self
    end
  private
    # Options passed to CSV.new based on dialect
    def csv_options
      {
        col_sep: (is_a?(Dialect) ? self : dialect).delimiter,
        row_sep: (is_a?(Dialect) ? self : dialect).lineTerminator,
        quote_char: (is_a?(Dialect) ? self : dialect).quoteChar,
        encoding: (is_a?(Dialect) ? self : dialect).encoding
      }
    end

    class DebugContext
      include Utils
      def initialize(*args, &block)
        @options = {}
        debug(*args, &block)
      end
    end
    def self.debug(*args, &block)
      DebugContext.new(*args, &block)
    end
  end

  class TableGroup < Metadata
    PROPERTIES = {
      :@id              => :link,
      :@type            => :atomic,
      notes:               :array,
      resources:           :array,
      tableSchema:         :object,
      tableDirection:      :atomic,
      dialect:             :object,
      transformations:     :array,
    }.freeze
    REQUIRED = [].freeze

    # Setters
    PROPERTIES.each do |a, type|
      next if a == :dialect
      define_method("#{a}=".to_sym) do |value|
        case type
        when :natural_language
          set_nl(a, value)
        else
          object[a] = value.to_s =~ /^\d+/ ? value.to_i : value
        end
      end
    end

    # Does the Metadata or any descendant have any common properties
    # @return [Boolean]
    def has_annotations?
      super || resources.any? {|t| t.has_annotations? }
    end

    # Logic for accessing elements as accessors
    def method_missing(method, *args)
      if INHERITED_PROPERTIES.has_key?(method.to_sym)
        inherited_property_value(method.to_sym)
      else
        PROPERTIES.has_key?(method.to_sym) ? object[method.to_sym] : super
      end
    end

    ##
    # Iterate over all resources
    # @yield [Table]
    def each_resource
      resources.map(&:url).each do |url|
        yield for_table(url)
      end
    end

    ##
    # Return the metadata for a specific table, re-basing context as necessary
    #
    # @param [String] url of the table
    # @return [Table]
    def for_table(url)
      # If there are no resources, assume there's one for this table
      #self.resources ||= [Table.new(url: url)]
      if table = Array(resources).detect {|t| t.url == url}
        # Set document base for this table for resolving URLs
        table.instance_variable_set(:@context, context.dup)
        table.context.base = url
        table
      end
    end

    # Return Annotated Table Group representation
    def to_atd
      {
        "@id" => id,
        "@type" => "AnnotatedTableGroup",
        "resources" => resources.map(&:to_atd)
      }
    end
  end

  class Table < Metadata
    PROPERTIES = {
      :@id              => :link,
      :@type            => :atomic,
      dialect:             :object,
      notes:               :array,
      suppressOutput:      :atomic,
      tableDirection:      :atomic,
      tableSchema:         :object,
      transformations:     :array,
      url:                 :link,
    }.freeze
    REQUIRED = [:url].freeze

    # Setters
    PROPERTIES.each do |a, type|
      next if a == :dialect
      define_method("#{a}=".to_sym) do |value|
        case type
        when :natural_language
          set_nl(a, value)
        else
          object[a] = value.to_s =~ /^\d+/ ? value.to_i : value
        end
      end
    end

    # Does the Metadata or any descendant have any common properties
    # @return [Boolean]
    def has_annotations?
      super || tableSchema && tableSchema.has_annotations?
    end

    # Return Annotated Table representation
    def to_atd
      {
        "@id" => id,
        "@type" => "AnnotatedTable",
        "columns" => tableSchema.columns.map(&:to_atd),
        "rows" => [],
        "url" => self.url.to_s
      }
    end

    # Logic for accessing elements as accessors
    def method_missing(method, *args)
      if INHERITED_PROPERTIES.has_key?(method.to_sym)
        inherited_property_value(method.to_sym)
      else
        PROPERTIES.has_key?(method.to_sym) ? object[method.to_sym] : super
      end
    end
  end

  class Transformation < Metadata
    PROPERTIES = {
      :@id         => :link,
      :@type       => :atomic,
      source:         :atomic,
      targetFormat:   :link,
      scriptFormat:   :link,
      title:          :natural_language,
      url:            :link,
    }.freeze
    REQUIRED = %w(url targetFormat scriptFormat).map(&:to_sym).freeze

    # Setters
    PROPERTIES.each do |a, type|
      define_method("#{a}=".to_sym) do |value|
        case type
        when :natural_language
          set_nl(a, value)
        else
          object[a] = value.to_s =~ /^\d+/ ? value.to_i : value
        end
      end
    end

    # Logic for accessing elements as accessors
    def method_missing(method, *args)
      PROPERTIES.has_key?(method.to_sym) ? object[method.to_sym] : super
    end
  end

  class Schema < Metadata
    PROPERTIES = {
      :@id       => :link,
      :@type     => :atomic,
      columns:      :array,
      foreignKeys:  :array,
      primaryKey:   :column_reference,
    }.freeze
    REQUIRED = [].freeze

    # Setters
    PROPERTIES.each do |a, type|
      define_method("#{a}=".to_sym) do |value|
        case type
        when :natural_language
          set_nl(a, value)
        else
          object[a] = value.to_s =~ /^\d+/ ? value.to_i : value
        end
      end
    end

    # Logic for accessing elements as accessors
    def method_missing(method, *args)
      if INHERITED_PROPERTIES.has_key?(method.to_sym)
        inherited_property_value(method.to_sym)
      else
        PROPERTIES.has_key?(method.to_sym) ? object[method.to_sym] : super
      end
    end
  end

  class Column < Metadata
    PROPERTIES = {
      :@id         => :link,
      :@type       => :atomic,
      name:           :atomic,
      suppressOutput: :atomic,
      title:          :natural_language,
      required:       :atomic,
      virtual:        :atomic,
    }.freeze
    REQUIRED = [].freeze

    ##
    # Table containing this column (if any)
    # @return [Table]
    def table; @options[:table]; end

    # Column number set on initialization
    # @return [Integer] 1-based colnum number
    def number
      @options.fetch(:number, 0)
    end

    # Source Column number set on initialization
    #
    # @note this is lazy evaluated to avoid dependencies on setting dialect vs. initializing columns
    # @return [Integer] 1-based colnum number
    def sourceNumber
      skipColumns = table ? (dialect.skipColumns.to_i + dialect.headerColumnCount.to_i) : 0
      number + skipColumns
    end

    # Does the Metadata or any descendant have any common properties
    # @return [Boolean]
    def has_annotations?
      super || columns.any? {|c| c.has_annotations? }
    end

    # Setters
    PROPERTIES.each do |a, type|
      define_method("#{a}=".to_sym) do |value|
        case type
        when :natural_language
          set_nl(a, value)
        else
          object[a] = value.to_s =~ /^\d+/ ? value.to_i : value
        end
      end
    end

    # Return or create a name for the column from title, if it exists
    def name
      object[:name] ||= if title && (ts = title[context.default_language || 'und'])
        n = Array(ts).first
        n0 = URI.encode(n[0,1], /[^a-zA-Z0-9]/)
        n1 = URI.encode(n[1..-1], /[^\w\.]/)
        "#{n0}#{n1}"
      end || "_col.#{number}"
    end

    # Identifier for this Column, as an RFC7111 fragment 
    # @return [RDF::URI]
    def id;
      url = table ? table.url : RDF::URI("")
      url + "#col=#{self.sourceNumber}";
    end

    # Return Annotated Column representation
    def to_atd
      {
        "@id" => id,
        "@type" => "Column",
        "table" => (table.id if table),
        "number" => self.number,
        "sourceNumber" => self.sourceNumber,
        "cells" => [],
        "virtual" => self.virtual,
        "name" => self.name,
        "title" => self.title
      }
    end

    # Logic for accessing elements as accessors
    def method_missing(method, *args)
      if INHERITED_PROPERTIES.has_key?(method.to_sym)
        inherited_property_value(method.to_sym)
      else
        PROPERTIES.has_key?(method.to_sym) ? object[method.to_sym] : super
      end
    end
  end

  class Dialect < Metadata
    # Defaults for dialects
    DIALECT_DEFAULTS = {
      commentPrefix:      nil,
      delimiter:          ",".freeze,
      doubleQuote:        true,
      encoding:           "utf-8".freeze,
      header:             true,
      headerColumnCount:  0,
      headerRowCount:     1,
      lineTerminator:     :auto, # SPEC says "\r\n"
      quoteChar:          '"',
      skipBlankRows:      false,
      skipColumns:        0,
      skipInitialSpace:   false,
      skipRows:           0,
      trim:               false
    }.freeze

    PROPERTIES = {
      :@id             => :link,
      :@type           => :atomic,
      commentPrefix:      :atomic,
      delimiter:          :atomic,
      doubleQuote:        :atomic,
      encoding:           :atomic,
      header:             :atomic,
      headerColumnCount:  :atomic,
      headerRowCount:     :atomic,
      lineTerminator:     :atomic,
      quoteChar:          :atomic,
      skipBlankRows:      :atomic,
      skipColumns:        :atomic,
      skipInitialSpace:   :atomic,
      skipRows:           :atomic,
      trim:               :atomic,
    }.freeze

    REQUIRED = [].freeze

    # Setters
    PROPERTIES.keys.each do |a|
      define_method("#{a}=".to_sym) do |value|
        object[a] = value.to_s =~ /^\d+/ ? value.to_i : value
      end
    end

    # escape character
    # @return [String]
    def escape_character
      self.doubleQuote ? '"' : '\\'
    end

    # default for headerRowCount is zero if header is false
    # @return [Integer]
    def headerRowCount
      object.fetch(:headerRowCount, self.header ? 1 : 0)
    end

    # default for trim comes from skipInitialSpace
    # @return [Boolean, String]
    def trim
      object.fetch(:trim, self.skipInitialSpace ? 'start' : false)
    end

    ##
    # Extract a new Metadata document from the file or data provided
    #
    # @param [#read, #to_s] input IO, or file path or URL
    # @param  [Hash{Symbol => Object}] options
    #   any additional options (see `RDF::Util::File.open_file`)
    # @return [Metadata] Tabular metadata
    # @see http://w3c.github.io/csvw/syntax/#parsing
    def embedded_metadata(input, options = {})
      options = options.dup
      options.delete(:context) # Don't accidentally use a passed context
      # Normalize input to an IO object
      if !input.respond_to?(:read)
        return ::RDF::Util::File.open_file(input.to_s) {|f| embedded_metadata(f, options.merge(base: input.to_s))}
      end

      table = {
        "url" => (options.fetch(:base, "")),
        "@type" => "Table",
        "tableSchema" => {
          "@type" => "Schema",
          "columns" => []
        }
      }

      # Set encoding on input
      csv = ::CSV.new(input, csv_options)
      (1..skipRows.to_i).each do
        value = csv.shift.join(delimiter)  # Skip initial lines, these form comment annotations
        # Trim value
        value.lstrip! if %w(true start).include?(trim.to_s)
        value.rstrip! if %w(true end).include?(trim.to_s)

        value = value[1..-1] if commentPrefix && value.start_with?(commentPrefix)
        table["notes"] ||= [] << value unless value.empty?
      end
      debug("embedded_metadata") {"notes: #{table["notes"].inspect}"}

      (1..headerRowCount).each do
        Array(csv.shift).each_with_index do |value, index|
          # Skip columns
          next if index < (skipColumns.to_i + headerColumnCount.to_i)

          # Trim value
          value.lstrip! if %w(true start).include?(trim.to_s)
          value.rstrip! if %w(true end).include?(trim.to_s)

          # Initialize title
          # SPEC CONFUSION: does title get an array, or concatenated values?
          columns = table["tableSchema"]["columns"] ||= []
          column = columns[index - skipColumns.to_i] ||= {
            "title" => {"und" => []},
          }
          column["title"]["und"] << value
        end
      end
      debug("embedded_metadata") {"table: #{table.inspect}"}
      input.rewind if input.respond_to?(:rewind)

      Table.new(table, options.merge(reason: "load embedded metadata: #{table['@id']}"))
    end

    # Logic for accessing elements as accessors
    def method_missing(method, *args)
      if DIALECT_DEFAULTS.has_key?(method.to_sym)
        # As set, or with default
        object.fetch(method.to_sym, DIALECT_DEFAULTS[method.to_sym])
      else
        super
      end
    end
  end

  # Wraps each resulting row
  class Row
    # Class for returning values
    Cell = Struct.new(:table, :column, :row, :stringValue, :aboutUrl, :propertyUrl, :valueUrl, :value, :errors) do
      def set_urls(mapped_values)
        %w(aboutUrl propertyUrl valueUrl).each do |prop|
          # If the cell value is nil, and it is not a virtual column
          next if prop == "valueUrl" && value.nil? && !column.virtual
          if v = column.send(prop.to_sym)
            t = Addressable::Template.new(v)
            mapped = t.expand(mapped_values).to_s
            # FIXME: don't expand here, do it in CSV2RDF
            url = row.context.expand_iri(mapped, documentRelative: true)
            self.send("#{prop}=".to_sym, url)
          end
        end
      end

      def valid?; Array(errors).empty?; end
      def to_s; value.to_s; end

      # Identifier for this Cell, as an RFC7111 fragment 
      # @return [RDF::URI]
      def id; table.url + "#cell=#{self.row.sourceNumber},#{self.column.sourceNumber}"; end

      # Return Annotated Cell representation
      def to_atd
        {
          "@id" => self.id,
          "@type" => "Cell",
          "column" => column.id,
          "row" => row.id,
          "stringValue" => self.stringValue,
          "value" => self.value,
          "errors" => self.errors
        }
      end
    end

    # Row values, hashed by `name`
    attr_reader :values

    # Row number of this row
    # @return [Integer]
    attr_reader :number

    # Row number of this row from the original source
    # @return [Integer]
    attr_reader :sourceNumber

    #
    # Table containing this row
    # @return [Table]
    attr_reader :table

    #
    # Context from Table with base set to table URL for expanding URI Templates
    # @return [JSON::LD::Context]
    attr_reader :context

    ##
    # @param [Array<Array<String>>] row
    # @param [Metadata] metadata for Table
    # @param [Integer] number 1-based row number after skipped/header rows
    # @param [Integer] source_number 1-based row number from source
    # @return [Row]
    def initialize(row, metadata, number, source_number)
      @table = metadata
      @number = number
      @sourceNumber = source_number
      @values = []
      skipColumns = metadata.dialect.skipColumns.to_i + metadata.dialect.headerColumnCount.to_i

      @context = table.context.dup
      @context.base = table.url

      # Create values hash
      # SPEC CONFUSION: are values pre-or-post conversion?
      map_values = {"_row" => number, "_sourceRow" => source_number}

      columns = metadata.tableSchema.columns ||= []

      # Make sure that the row length is at least as long as the number of column definitions, to implicitly include virtual columns
      columns.each_with_index {|c, index| row[index] ||= (c.null || '')}
      row.each_with_index do |value, index|
        next if index < skipColumns

        cell_errors = []

        # create column if necessary
        columns[index - skipColumns] ||=
          Column.new({}, table: metadata, parent: metadata.tableSchema, number: index + 1 - skipColumns)

        column = columns[index - skipColumns]

        @values << cell = Cell.new(metadata, column, self, value)

        datatype = metadata.normalize_datatype(column.datatype || 'string')
        value = value.gsub(/\r\t\a/, ' ') unless %w(string json xml html anyAtomicType any).include?(datatype[:base])
        value = value.strip.gsub(/\s+/, ' ') unless %w(string json xml html anyAtomicType any normalizedString).include?(datatype[:base])
        # if the resulting string is an empty string, apply the remaining steps to the string given by the default property
        value = column.default || '' if value.empty?

        cell_values = column.separator ? value.split(column.separator) : [value]

        cell_values = cell_values.map do |v|
          v = v.strip unless %w(string anyAtomicType any).include?(datatype[:base])
          v = column.default || '' if v.empty?
          if Array(column.null).include?(v)
            nil
          else
            # Trim value
            if %w(string anyAtomicType any).include?(datatype[:base])
              v.lstrip! if %w(true start).include?(metadata.dialect.trim.to_s)
              v.rstrip! if %w(true end).include?(metadata.dialect.trim.to_s)
            else
              # unless the datatype is string or anyAtomicType or any, strip leading and trailing whitespace from the string value
              v.strip!
            end

            expanded_dt = metadata.context.expand_iri(datatype[:base], vocab: true)
            if (lit_or_errors = value_matching_datatype(v.dup, datatype, expanded_dt, column.lang)).is_a?(RDF::Literal)
              lit_or_errors
            else
              cell_errors += lit_or_errors
              RDF::Literal(v, language: column.lang)
            end
          end
        end.compact

        cell.value = (column.separator ? cell_values : cell_values.first)
        cell.errors = cell_errors
        metadata.send(:debug, "#{self.number}: each_cell ##{self.sourceNumber},#{cell.column.sourceNumber}", cell.errors.join("\n")) unless cell_errors.empty?

        map_values[columns[index].name] =  (column.separator ? cell_values.map(&:to_s) : cell_values.first.to_s)
      end

      # Map URLs for row
      @values.each_with_index do |cell, index|
        mapped_values = map_values.merge(
          "_name" => URI.decode(cell.column.name),
          "_column" => cell.column.number,
          "_sourceColumn" => cell.column.sourceNumber
        )
        cell.set_urls(mapped_values)
      end
    end

    # Identifier for this row, as an RFC7111 fragment 
    # @return [RDF::URI]
    def id; table.url + "#row=#{self.sourceNumber}"; end

    # Return Annotated Row representation
    def to_atd
      {
        "@id" => self.id,
        "@type" => "Row",
        "table" => table.id,
        "number" => self.number,
        "sourceNumber" => self.sourceNumber,
        "cells" => @values.map(&:to_atd)
      }
    end

  private
    #
    # given a datatype specification, return a literal matching that specififcation, if found, otherwise nil
    # @return [RDF::Literal]
    def value_matching_datatype(value, datatype, expanded_dt, language)
      value_errors = []

      # Check constraints
      if datatype[:length] && value.length != datatype[:length]
        value_errors << "#{value} does not have length #{datatype[:length]}"
      end
      if datatype[:minLength] && value.length < datatype[:minLength]
        value_errors << "#{value} does not have length >= #{datatype[:minLength]}"
      end
      if datatype[:maxLength] && value.length > datatype[:maxLength]
        value_errors << "#{value} does not have length <= #{datatype[:maxLength]}"
      end

      format = datatype[:format]
      # Datatype specific constraints and conversions
      case datatype[:base].to_sym
      when :decimal, :integer, :long, :int, :short, :byte,
           :nonNegativeInteger, :positiveInteger,
           :unsignedLong, :unsignedInt, :unsignedShort, :unsignedByte,
           :nonPositiveInteger, :negativeInteger,
           :double, :float, :number
        # Normalize representation based on numeric-specific facets
        groupChar = datatype.fetch(:groupChar, ',')
        if datatype[:pattern] && !value.match(Regexp.new(datatype[:pattern]))
          # pattern facet failed
          value_errors << "#{value} does not match pattern #{datatype[:pattern]}"
        end
        if value.include?(groupChar*2)
          # pattern facet failed
          value_errors << "#{value} has repeating #{groupChar.inspect}"
        end
        value.gsub!(groupChar, '')
        value.sub!(datatype.fetch(:decimalChar, '.'), '.')

        # Extract percent or per-mille sign
        percent = permille = false
        case value
        when /%$/
          value = value[0..-2]
          percent = true
        when /‰$/
          value = value[0..-2]
          permille = true
        end

        lit = RDF::Literal(value, datatype: expanded_dt)
        if percent || permille
          o = lit.object
          o = o / 100 if percent
          o = o / 1000 if permille
          lit = RDF::Literal(o, datatype: expanded_dt)
        end
      when :boolean
        lit = if format
          # True/False determined by Y|N values
          t, f = format.to_s.split('|', 2)
          case
          when value == t
            value = RDF::Literal::TRUE
          when value == f
            value = RDF::Literal::FALSE
          else
            value_errors << "#{value} does not match boolean format #{format}"
            RDF::Literal::Boolean.new(value)
          end
        else
          if %w(1 true).include?(value.downcase)
            RDF::Literal::TRUE
          elsif %w(0 false).include?(value.downcase)
            RDF::Literal::FALSE
          end
        end
      when :date, :time, :dateTime, :dateTimeStamp, :datetime
        # Match values
        tz, date_format, time_format = nil, nil, nil

        # Extract tz info
        if format && (md = format.match(/^(.*[dyms])+(\s*[xX]{1,5})$/))
          format, tz = md[1], md[2]
        end

        if format
          date_format, time_format = format.split(' ')
          if datatype[:base].to_sym == :time
            date_format, time_format = nil, date_format
          end

          # Extract date, of specified
          date_part = case date_format
          when 'yyyy-MM-dd' then value.match(/^(?<yr>\d{4})-(?<mo>\d{2})-(?<da>\d{2})/)
          when 'yyyyMMdd'   then value.match(/^(?<yr>\d{4})(?<mo>\d{2})(?<da>\d{2})/)
          when 'dd-MM-yyyy' then value.match(/^(?<da>\d{2})-(?<mo>\d{2})-(?<yr>\d{4})/)
          when 'd-M-yyyy'   then value.match(/^(?<da>\d{1,2})-(?<mo>\d{1,2})-(?<yr>\d{4})/)
          when 'MM-dd-yyyy' then value.match(/^(?<mo>\d{2})-(?<da>\d{2})-(?<yr>\d{4})/)
          when 'M-d-yyyy'   then value.match(/^(?<mo>\d{1,2})-(?<da>\d{1,2})-(?<yr>\d{4})/)
          when 'dd/MM/yyyy' then value.match(/^(?<da>\d{2})\/(?<mo>\d{2})\/(?<yr>\d{4})/)
          when 'd/M/yyyy'   then value.match(/^(?<da>\d{1,2})\/(?<mo>\d{1,2})\/(?<yr>\d{4})/)
          when 'MM/dd/yyyy' then value.match(/^(?<mo>\d{2})\/(?<da>\d{2})\/(?<yr>\d{4})/)
          when 'M/d/yyyy'   then value.match(/^(?<mo>\d{1,2})\/(?<da>\d{1,2})\/(?<yr>\d{4})/)
          when 'dd.MM.yyyy' then value.match(/^(?<da>\d{2})\.(?<mo>\d{2})\.(?<yr>\d{4})/)
          when 'd.M.yyyy'   then value.match(/^(?<da>\d{1,2})\.(?<mo>\d{1,2})\.(?<yr>\d{4})/)
          when 'MM.dd.yyyy' then value.match(/^(?<mo>\d{2})\.(?<da>\d{2})\.(?<yr>\d{4})/)
          when 'M.d.yyyy'   then value.match(/^(?<mo>\d{1,2})\.(?<da>\d{1,2})\.(?<yr>\d{4})/)
          when 'yyyy-MM-ddTHH:mm:ss' then value.match(/^(?<yr>\d{4})-(?<mo>\d{2})-(?<da>\d{2})T(?<hr>\d{2}):(?<mi>\d{2}):(?<se>\d{2})/)
          when 'yyyy-MM-ddTHH:mm' then value.match(/^(?<yr>\d{4})-(?<mo>\d{2})-(?<da>\d{2})T(?<hr>\d{2}):(?<mi>\d{2})(?<se>)/)
          else
            value_errors << "unrecognized date/time format #{date_format}" if date_format
            nil
          end

          # Forward past date part
          if date_part
            value = value[date_part.to_s.length..-1]
            value = value.lstrip if date_part && value.start_with?(' ')
          end

          # Extract time, of specified
          time_part = case time_format
          when 'HH:mm:ss' then value.match(/^(?<hr>\d{2}):(?<mi>\d{2}):(?<se>\d{2})/)
          when 'HHmmss'   then value.match(/^(?<hr>\d{2})(?<mi>\d{2})(?<se>\d{2})/)
          when 'HH:mm'    then value.match(/^(?<hr>\d{2}):(?<mi>\d{2})(?<se>)/)
          when 'HHmm'     then value.match(/^(?<hr>\d{2})(?<mi>\d{2})(?<se>)/)
          else
            value_errors << "unrecognized date/time format #{time_format}" if time_format
            nil
          end

          # Forward past time part
          value = value[time_part.to_s.length..-1] if time_part

          # Use datetime match for time
          time_part = date_part if date_part && date_part.names.include?("hr")

          # If there's a timezone, it may optionally start with whitespace
          value = value.lstrip if tz.to_s.start_with?(' ')
          tz_part = value if tz

          # Compose normalized value
          vd = ("%04d-%02d-%02d" % [date_part[:yr], date_part[:mo], date_part[:da]]) if date_part
          vt = ("%02d:%02d:%02d" % [time_part[:hr], time_part[:mi], time_part[:se].to_i]) if time_part
          value = [vd, vt].compact.join('T')
          value += tz_part.to_s
        end

        lit = RDF::Literal(value, datatype: expanded_dt)
      when :duration, :dayTimeDuration, :yearMonthDuration
        # SPEC CONFUSION: surely format also includes that for other duration types?
        lit = RDF::Literal(value, datatype: expanded_dt)
      when :anyType, :anySimpleType, :ENTITIES, :IDREFS, :NMTOKENS,
           :ENTITY, :ID, :IDREF, :NOTATION
        value_errors << "#{value} uses unsupported datatype: #{datatype[:base]}"
      else
        # For other types, format is a regexp
        unless format.nil? || value.match(Regexp.new(format))
          value_errors << "#{value} does not match format #{format}"
        end
        lit = if value_errors.empty?
          if expanded_dt == RDF::XSD.string
            # Type string will still use language
            RDF::Literal(value, language: language)
          else
            RDF::Literal(value, datatype: expanded_dt)
          end
        end
      end

      # Final value is a valid literal, or a plain literal otherwise
      value_errors << "#{value} is not a valid #{datatype[:base]}" if lit && !lit.valid?

      # FIXME Value constraints

      value_errors.empty? ? lit : value_errors
    end
  end

  # Metadata errors detected
  class Error < StandardError; end
end
