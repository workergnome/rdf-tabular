require 'rdf'

module RDF::Tabular
  ##
  # A Tabular Data to RDF parser in Ruby.
  #
  # @author [Gregg Kellogg](http://greggkellogg.net/)
  class Reader < RDF::Reader
    format Format
    include Utils

    # Metadata associated with the CSV
    #
    # @return [Metadata]
    attr_reader :metadata

    ##
    # Input open to read
    # @return [:read]
    attr_reader :input

    ##
    # Initializes the RDF::Tabular Reader instance.
    #
    # @param  [Util::File::RemoteDoc, IO, StringIO, Array<Array<String>>, String]       input
    #   An opened file possibly JSON Metadata,
    #   or an Array used as an internalized array of arrays
    # @param  [Hash{Symbol => Object}] options
    #   any additional options (see `RDF::Reader#initialize`)
    # @option options [Metadata, Hash, String, RDF::URI] :metadata user supplied metadata, merged on top of extracted metadata. If provided as a URL, Metadata is loade from that location
    # @option options [Boolean] :minimal includes only the information gleaned from the cells of the tabular data
    # @option options [Boolean] :noProv do not output optional provenance information
    # @option options [Array] :warnings
    #   array for placing warnings found when processing metadata. If not set, and validating, warnings are output to `$stderr`
    # @yield  [reader] `self`
    # @yieldparam  [RDF::Reader] reader
    # @yieldreturn [void] ignored
    # @raise [RDF::ReaderError] if the CSV document cannot be loaded
    def initialize(input = $stdin, options = {}, &block)
      super do
        # Base would be how we are to take this
        @options[:base] ||= base_uri.to_s if base_uri
        @options[:base] ||= input.base_uri if input.respond_to?(:base_uri)
        @options[:base] ||= input.path if input.respond_to?(:path)
        @options[:base] ||= input.filename if input.respond_to?(:filename)
        if RDF::URI(@options[:base]).relative? && File.exist?(@options[:base].to_s)
          @options[:base] = "file:/#{File.expand_path(@options[:base])}"
        end

        @options[:depth] ||= 0

        debug("Reader#initialize") {"input: #{input.inspect}, base: #{@options[:base]}"}

        # Minimal implies noProv
        @options[:noProv] ||= @options[:minimal]

        #byebug if input.is_a?(Array)
        @input = case input
        when String then StringIO.new(input)
        when Array then StringIO.new(input.map {|r| r.join(",")}.join("\n"))
        else input
        end

        depth do
          # If input is JSON, then the input is the metadata
          if @options[:base] =~ /\.json(?:ld)?$/ ||
             @input.respond_to?(:content_type) && @input.content_type =~ %r(application/(?:ld+)json)
            @metadata = Metadata.new(@input, @options.merge(filenames: @options[:base]))
            # If @metadata is for a Table, turn it into a TableGroup
            @metadata = @metadata.to_table_group if @metadata.is_a?(Table)
            @metadata.normalize!
            @input = @metadata
          elsif @options[:no_found_metadata]
            # Extract embedded metadata and merge
            dialect_metadata = @options[:metadata] || Table.new({}, context: "http://www.w3.org/ns/csvw")
            dialect = dialect_metadata.dialect.dup

            # HTTP flags for setting header values
            dialect.header = false if (input.headers.fetch(:content_type, '').split(';').include?('header=absent') rescue false)
            dialect.encoding = input.charset if (input.charset rescue nil)
            dialect.separator = "\t" if (input.content_type == "text/tsv" rescue nil)
            embed_options = {base: "http://example.org/default-metadata"}.merge(@options)
            embedded_metadata = dialect.embedded_metadata(input, embed_options)

            if (@metadata = @options[:metadata]) && @metadata.tableSchema
              @metadata.verify_compatible!(embedded_metadata)
            else
              @metadata = embedded_metadata
            end

            lang = input.headers[:content_language] rescue nil
            lang = nil if lang.to_s.include?(',') # Not for multiple languages
            # Set language, if unset and provided
            @metadata.lang ||= lang if lang 
              
            @metadata.dialect = dialect
          else
            # It's tabluar data. Find metadata and proceed as if it was specified in the first place
            @options[:original_input] = @input
            @input = @metadata = Metadata.for_input(@input, @options)
          end

          debug("Reader#initialize") {"input: #{input}, metadata: #{metadata.inspect}"}

          if block_given?
            case block.arity
              when 0 then instance_eval(&block)
              else block.call(self)
            end
          end
        end
      end
    end

    ##
    # @private
    # @see   RDF::Reader#each_statement
    def each_statement(&block)
      if block_given?
        @callback = block

        start_time = Time.now

        # Construct metadata from that passed from file open, along with information from the file.
        if input.is_a?(Metadata)
          debug("each_statement: metadata") {input.inspect}

          depth do
            # Get Metadata to invoke and open referenced files
            case input.type
            when :TableGroup
              begin
                # Validate metadata
                input.validate!

                # Use resolved @id of TableGroup, if available
                table_group = input.id || RDF::Node.new
                add_statement(0, table_group, RDF.type, CSVW.TableGroup) unless minimal?

                # Common Properties
                input.each do |key, value|
                  next unless key.to_s.include?(':') || key == :notes
                  input.common_properties(table_group, key, value) do |statement|
                    add_statement(0, statement)
                  end
                end unless minimal?

                # If we were originally given tabular data as input, simply use that, rather than opening the table URL. This allows buffered data to be used as input
                if Array(input.tables).empty? && options[:original_input]
                  table_resource = RDF::Node.new
                  add_statement(0, table_group, CSVW.table, table_resource) unless minimal?
                  Reader.new(options[:original_input], options.merge(
                      no_found_metadata: true,
                      table_resource: table_resource
                  )) do |r|
                    r.each_statement(&block)
                  end
                else
                  input.each_table do |table|
                    next if table.suppressOutput
                    table_resource = table.id || RDF::Node.new
                    add_statement(0, table_group, CSVW.table, table_resource) unless minimal?
                    Reader.open(table.url, options.merge(
                        format: :tabular,
                        metadata: table,
                        base: table.url,
                        no_found_metadata: true,
                        table_resource: table_resource
                    )) do |r|
                      r.each_statement(&block)
                    end
                  end
                end

                # Provenance
                if prov?
                  activity = RDF::Node.new
                  add_statement(0, table_group, RDF::PROV.wasGeneratedBy, activity)
                  add_statement(0, activity, RDF.type, RDF::PROV.Activity)
                  add_statement(0, activity, RDF::PROV.wasAssociatedWith, RDF::URI("http://rubygems.org/gems/rdf-tabular"))
                  add_statement(0, activity, RDF::PROV.startedAtTime, RDF::Literal::DateTime.new(start_time))
                  add_statement(0, activity, RDF::PROV.endedAtTime, RDF::Literal::DateTime.new(Time.now))

                  unless (urls = input.tables.map(&:url)).empty?
                    usage = RDF::Node.new
                    add_statement(0, activity, RDF::PROV.qualifiedUsage, usage)
                    add_statement(0, usage, RDF.type, RDF::PROV.Usage)
                    urls.each do |url|
                      add_statement(0, usage, RDF::PROV.entity, RDF::URI(url))
                    end
                    add_statement(0, usage, RDF::PROV.hadRole, CSVW.csvEncodedTabularData)
                  end

                  unless Array(input.filenames).empty?
                    usage = RDF::Node.new
                    add_statement(0, activity, RDF::PROV.qualifiedUsage, usage)
                    add_statement(0, usage, RDF.type, RDF::PROV.Usage)
                    Array(input.filenames).each do |fn|
                      add_statement(0, usage, RDF::PROV.entity, RDF::URI(fn))
                    end
                    add_statement(0, usage, RDF::PROV.hadRole, CSVW.tabularMetadata)
                  end
                end
              ensure
                warnings = @options.fetch(:warnings, []).concat(input.warnings)
                if validate? && !warnings.empty? && !@options[:warnings]
                  $stderr.puts "Warnings: #{warnings.join("\n")}"
                end
              end
            when :Table
              Reader.open(input.url, options.merge(format: :tabular, metadata: input, base: input.url, no_found_metadata: true)) do |r|
                r.each_statement(&block)
              end
            else
              raise "Opened inappropriate metadata type: #{input.type}"
            end
          end
          return
        end

        # Output Table-Level RDF triples
        table_resource = options.fetch(:table_resource, (metadata.id || RDF::Node.new))
        unless minimal?
          add_statement(0, table_resource, RDF.type, CSVW.Table)
          add_statement(0, table_resource, CSVW.url, RDF::URI(metadata.url))
        end

        # Common Properties
        metadata.each do |key, value|
          next unless key.to_s.include?(':') || key == :notes
          metadata.common_properties(table_resource, key, value) do |statement|
            add_statement(0, statement)
          end
        end unless minimal?

        # Input is file containing CSV data.
        # Output ROW-Level statements
        last_row_num = 0
        metadata.each_row(input) do |row|
          if row.is_a?(RDF::Statement)
            # May add additional comments
            row.subject = table_resource
            add_statement(last_row_num + 1, row)
            next
          end
          last_row_num = row.sourceNumber

          # Output row-level metadata
          row_resource = RDF::Node.new
          default_cell_subject = RDF::Node.new
          unless minimal?
            add_statement(row.sourceNumber, table_resource, CSVW.row, row_resource)
            add_statement(row.sourceNumber, row_resource, CSVW.rownum, row.number)
            add_statement(row.sourceNumber, row_resource, RDF.type, CSVW.Row)
            add_statement(row.sourceNumber, row_resource, CSVW.url, row.id)
          end
          row.values.each_with_index do |cell, index|
            next if cell.column.suppressOutput # Skip ignored cells
            cell_subject = cell.aboutUrl || default_cell_subject
            propertyUrl = cell.propertyUrl || RDF::URI("#{metadata.url}##{cell.column.name}")
            add_statement(row.sourceNumber, row_resource, CSVW.describes, cell_subject) unless minimal?

            if cell.column.valueUrl
              add_statement(row.sourceNumber, cell_subject, propertyUrl, cell.valueUrl) if cell.valueUrl
            elsif cell.column.ordered && cell.column.separator
              list = RDF::List[*Array(cell.value)]
              add_statement(row.sourceNumber, cell_subject, propertyUrl, list.subject)
              list.each_statement do |statement|
                next if statement.predicate == RDF.type && statement.object == RDF.List
                add_statement(row.sourceNumber, statement.subject, statement.predicate, statement.object)
              end
            else
              Array(cell.value).each do |v|
                add_statement(row.sourceNumber, cell_subject, propertyUrl, v)
              end
            end
          end
        end
      end
      enum_for(:each_statement)
    end

    ##
    # @private
    # @see   RDF::Reader#each_triple
    def each_triple(&block)
      if block_given?
        each_statement do |statement|
          block.call(*statement.to_triple)
        end
      end
      enum_for(:each_triple)
    end

    ##
    # Transform to JSON. Note that this must be run from within the reader context if the input is an open IO stream.
    #
    # @example outputing annotated CSV as JSON
    #     result = nil
    #     RDF::Tabular::Reader.open("etc/doap.csv") do |reader|
    #       result = reader.to_json
    #     end
    #     result #=> {...}
    #
    # @example outputing annotated CSV as JSON from an in-memory structure
    #     csv = %(
    #       GID,On Street,Species,Trim Cycle,Inventory Date
    #       1,ADDISON AV,Celtis australis,Large Tree Routine Prune,10/18/2010
    #       2,EMERSON ST,Liquidambar styraciflua,Large Tree Routine Prune,6/2/2010
    #       3,EMERSON ST,Liquidambar styraciflua,Large Tree Routine Prune,6/2/2010
    #     ).gsub(/^\s+/, '')
    #     r = RDF::Tabular::Reader.new(csv)
    #     r.to_json #=> {...}
    #
    # @param [Hash{Symbol => Object}] options may also be a JSON state
    # @option options [IO, StringIO] io to output to file
    # @option options [::JSON::State] :state used when dumping
    # @option options [Boolean] :atd output Abstract Table representation instead
    # @return [String]
    def to_json(options = @options)
      io = case options
      when IO, StringIO then options
      when Hash then options[:io]
      end
      json_state = case options
      when Hash
        case
        when options.has_key?(:state) then options[:state]
        when options.has_key?(:indent) then options
        else ::JSON::LD::JSON_STATE
        end
      when ::JSON::State, ::JSON::Ext::Generator::State, ::JSON::Pure::Generator::State
        options
      else ::JSON::LD::JSON_STATE
      end
      options = {} unless options.is_a?(Hash)

      hash_fn = options[:atd] ? :to_atd : :to_hash
      options = options.merge(noProv: @options[:noProv])

      if io
        ::JSON::dump_default_options = json_state
        ::JSON.dump(self.send(hash_fn, options), io)
      else
        hash = self.send(hash_fn, options)
        ::JSON.generate(hash, json_state)
      end
    end

    ##
    # Return a hash representation of the data for JSON serialization
    #
    # Produces an array if run in minimal mode.
    #
    # @param [Hash{Symbol => Object}] options
    # @return [Hash, Array]
    def to_hash(options = {})
      # Construct metadata from that passed from file open, along with information from the file.
      if input.is_a?(Metadata)
        debug("each_statement: metadata") {input.inspect}
        depth do
          # Get Metadata to invoke and open referenced files
          case input.type
          when :TableGroup
            begin
              # Validate metadata
              input.validate!

              tables = []
              table_group = {}
              table_group['@id'] = input.id.to_s if input.id

              # Common Properties
              input.each do |key, value|
                next unless key.to_s.include?(':') || key == :notes
                table_group[key] = input.common_properties(nil, key, value)
                table_group[key] = [table_group[key]] if key == :notes && !table_group[key].is_a?(Array)
              end

              table_group['table'] = tables

              if input.tables.empty? && options[:original_input]
                Reader.new(options[:original_input], options.merge(
                    base:               options.fetch(:base, "http://example.org/default-metadata"),
                    minimal:            minimal?,
                    no_found_metadata: true
                )) do |r|
                  case table = r.to_hash(options)
                  when Array then tables += table
                  when Hash  then tables << table
                  end
                end
              else
                input.each_table do |table|
                  next if table.suppressOutput
                  Reader.open(table.url, options.merge(
                    format:             :tabular,
                    metadata:           table,
                    base:               table.url,
                    minimal:            minimal?,
                    no_found_metadata:  true
                  )) do |r|
                    case table = r.to_hash(options)
                    when Array then tables += table
                    when Hash  then tables << table
                    end
                  end
                end
              end

              # Result is table_group or array
              minimal? ? tables : table_group
            ensure
              warnings = options.fetch(:warnings, []).concat(input.warnings)
              if validate? && !warnings.empty? && !@options[:warnings]
                $stderr.puts "Warnings: #{warnings.join("\n")}"
              end
            end
          when :Table
            table = nil
            Reader.open(input.url, options.merge(
              format:             :tabular,
              metadata:           input,
              base:               input.url,
              minimal:            minimal?,
              no_found_metadata:  true
            )) do |r|
              table = r.to_hash(options)
            end

            table
          else
            raise "Opened inappropriate metadata type: #{input.type}"
          end
        end
      else
        rows = []
        table = {}
        table['@id'] = metadata.id.to_s if metadata.id
        table['url'] = metadata.url.to_s

        # Use string values notes and common properties
        metadata.each do |key, value|
          next unless key.to_s.include?(':') || key == :notes
          table[key] = metadata.common_properties(nil, key, value)
          table[key] = [table[key]] if key == :notes && !table[key].is_a?(Array)
        end unless minimal?

        table.merge!("row" => rows)

        # Input is file containing CSV data.
        # Output ROW-Level statements
        metadata.each_row(input) do |row|
          if row.is_a?(RDF::Statement)
            # May add additional comments
            table['rdfs:comment'] ||= []
            table['rdfs:comment'] << row.object.to_s
            next
          end
          # Output row-level metadata
          r, a, values = {}, {}, {}
          r["url"] = row.id.to_s
          r["rownum"] = row.number

          row.values.each_with_index do |cell, index|
            column = metadata.tableSchema.columns[index]

            # Ignore suppressed columns
            next if column.suppressOutput

            # Skip valueUrl cells where the valueUrl is null
            next if cell.column.valueUrl && cell.valueUrl.nil?

            # Skip empty sequences
            next if !cell.column.valueUrl && cell.value.is_a?(Array) && cell.value.empty?

            subject = cell.aboutUrl || 'null'
            co = (a[subject.to_s] ||= {})
            co['@id'] = subject.to_s unless subject == 'null'
            prop = case cell.propertyUrl
            when RDF.type then '@type'
            when nil then column.name
            else
              # Compact the property to a term or prefixed name
              metadata.context.compact_iri(cell.propertyUrl, vocab: true)
            end

            value = case
            when prop == '@type'
              metadata.context.compact_iri(cell.valueUrl || cell.value, vocab: true)
            when cell.valueUrl
              unless subject == cell.valueUrl
                values[cell.valueUrl.to_s] ||= {o: co, prop: prop, count: 0}
                values[cell.valueUrl.to_s][:count] += 1
              end
              cell.valueUrl.to_s
            when cell.value.is_a?(RDF::Literal::Numeric)
              cell.value.object
            when cell.value.is_a?(RDF::Literal::Boolean)
              cell.value.object
            when cell.value
              cell.value
            end

            # Add or merge value
            merge_compacted_value(co, prop, value) unless value.nil?
          end

          # Check for nesting
          values.keys.each do |valueUrl|
            next unless a.has_key?(valueUrl)
            ref = values[valueUrl]
            co = ref[:o]
            prop = ref[:prop]
            next if ref[:count] != 1
            raise "Expected #{ref[o][prop].inspect} to include #{valueUrl.inspect}" unless Array(co[prop]).include?(valueUrl)
            co[prop] = Array(co[prop]).map {|e| e == valueUrl ? a.delete(valueUrl) : e}
            co[prop] = co[prop].first if co[prop].length == 1
          end

          r["describes"] = a.values

          if minimal?
            rows.concat(r["describes"])
          else
            rows << r
          end
        end

        minimal? ? table["row"] : table
      end
    end

    # Return a hash representation of the annotated tabular data model for JSON serialization
    # @param [Hash{Symbol => Object}] options
    # @return [Hash]
    def to_atd(options = {})
      # Construct metadata from that passed from file open, along with information from the file.
      if input.is_a?(Metadata)
        debug("each_statement: metadata") {input.inspect}
        depth do
          # Get Metadata to invoke and open referenced files
          case input.type
          when :TableGroup
            table_group = input.to_atd
            if input.tables.empty? && options[:original_input]
              Reader.new(options[:original_input], options.merge(
                  base:               options.fetch(:base, "http://example.org/default-metadata"),
                  no_found_metadata: true
              )) do |r|
                table_group["tables"] << r.to_atd(options)
              end
            else
              input.each_table do |table|
                Reader.open(table.url, options.merge(
                  metadata:           table,
                  base:               table.url,
                  no_found_metadata:  true
                )) do |r|
                  table_group["tables"] << r.to_atd(options)
                end
              end
            end

            # Result is table_group
            table_group
          when :Table
            table = nil
            Reader.open(input.url, options.merge(
              metadata:           input,
              base:               input.url,
              no_found_metadata:  true
            )) do |r|
              table = r.to_atd(options)
            end

            table
          else
            raise "Opened inappropriate metadata type: #{input.type}"
          end
        end
      else
        rows = []
        table = metadata.to_atd
        rows, columns = table["rows"], table["columns"]

        # Input is file containing CSV data.
        # Output ROW-Level statements
        metadata.each_row(input) do |row|
          rows << row.to_atd
          row.values.each_with_index do |cell, colndx|
            columns[colndx]["cells"] << cell.to_atd
          end
        end
        table
      end
    end

    def minimal?; @options[:minimal]; end
    def prov?; !(@options[:noProv]); end

    private
    ##
    # @overload add_statement(lineno, statement)
    #   Add a statement, object can be literal or URI or bnode
    #   @param [String] lineno
    #   @param [RDF::Statement] statement
    #   @yield [RDF::Statement]
    #   @raise [ReaderError] Checks parameter types and raises if they are incorrect if parsing mode is _validate_.
    #
    # @overload add_statement(lineno, subject, predicate, object)
    #   Add a triple
    #   @param [URI, BNode] subject the subject of the statement
    #   @param [URI] predicate the predicate of the statement
    #   @param [URI, BNode, Literal] object the object of the statement
    #   @raise [ReaderError] Checks parameter types and raises if they are incorrect if parsing mode is _validate_.
    def add_statement(node, *args)
      statement = args[0].is_a?(RDF::Statement) ? args[0] : RDF::Statement.new(*args)
      raise RDF::ReaderError, "#{statement.inspect} is invalid" if validate? && statement.invalid?
      debug(node) {"statement: #{RDF::NTriples.serialize(statement)}".chomp}
      @callback.call(statement)
    end

    # Merge values into compacted results, creating arrays if necessary
    def merge_compacted_value(hash, key, value)
      return unless hash
      case hash[key]
      when nil then hash[key] = value
      when Array
        if value.is_a?(Array)
          hash[key].concat(value)
        else
          hash[key] << value
        end
      else
        hash[key] = [hash[key]]
        if value.is_a?(Array)
          hash[key].concat(value)
        else
          hash[key] << value
        end
      end
    end
  end
end

