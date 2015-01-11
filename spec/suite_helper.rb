$:.unshift "."
require 'spec_helper'
require 'rdf/turtle'
require 'json/ld'
require 'open-uri'

# For now, override RDF::Utils::File.open_file to look for the file locally before attempting to retrieve it
module RDF::Util
  module File
    REMOTE_PATH = "http://w3c.github.io/csvw/"
    LOCAL_PATH = ::File.expand_path("../w3c-csvw", __FILE__) + '/'

    ##
    # Override to use Patron for http and https, Kernel.open otherwise.
    #
    # @param [String] filename_or_url to open
    # @param  [Hash{Symbol => Object}] options
    # @option options [Array, String] :headers
    #   HTTP Request headers.
    # @return [IO] File stream
    # @yield [IO] File stream
    def self.open_file(filename_or_url, options = {}, &block)
      case filename_or_url.to_s
      when /^file:/
        path = filename_or_url[5..-1]
        Kernel.open(path.to_s, &block)
      when 'http://www.w3.org/ns/csvw'
        Kernel.open(::File.join(LOCAL_PATH, "ns/csvw.jsonld"), &block)
      when /^#{REMOTE_PATH}/
        begin
          #puts "attempt to open #{filename_or_url} locally"
          if response = ::File.open(filename_or_url.to_s.sub(REMOTE_PATH, LOCAL_PATH))
            #puts "use #{filename_or_url} locally"
            case filename_or_url.to_s
            when /\.html$/
              def response.content_type; 'text/html'; end
            when /\.ttl$/
              def response.content_type; 'text/turtle'; end
            when /\.json$/
              def response.content_type; 'application/json'; end
            when /\.jsonld$/
              def response.content_type; 'application/ld+json'; end
            else
              def response.content_type; 'unknown'; end
            end

            if block_given?
              begin
                yield response
              ensure
                response.close
              end
            else
              response
            end
          else
            Kernel.open(filename_or_url.to_s, &block)
          end
        rescue Errno::ENOENT
          # Not there, don't run tests
          StringIO.new("")
        end
      else
        Kernel.open(filename_or_url.to_s, &block)
      end
    end
  end
end

module Fixtures
  module SuiteTest
    BASE = "http://w3c.github.io/csvw/tests/"
    FRAME = JSON.parse(%q({
      "@context": {
        "xsd": "http://www.w3.org/2001/XMLSchema#",
        "rdfs": "http://www.w3.org/2000/01/rdf-schema#",
        "mf": "http://www.w3.org/2001/sw/DataAccess/tests/test-manifest#",
        "mq": "http://www.w3.org/2001/sw/DataAccess/tests/test-query#",
        "csvt": "http://w3c.github.io/csvw/tests/vocab#",

        "id": "@id",
        "type": "@type",
        "name": "mf:name",
        "comment": "rdfs:comment",
        "entries": {"@id": "mf:entries", "@type": "@id", "@container": "@list"},
        "action":  {"@id": "mf:action", "@type": "@id"},
        "approval":  {"@id": "csvt:approval", "@type": "@id"},
        "data": {"@id": "mq:data", "@type": "@id"},
        "result": {"@id": "mf:result", "@type": "@id"}
      },
      "@type": "mf:Manifest",
      "entries": {}
    }))
 
    class Manifest < JSON::LD::Resource
      def self.open(file)
        #puts "open: #{file}"
        prefixes = {}
        g = RDF::Repository.load(file, format:  :ttl)
        JSON::LD::API.fromRDF(g) do |expanded|
          JSON::LD::API.frame(expanded, FRAME) do |framed|
            yield Manifest.new(framed['@graph'].first)
          end
        end
      end

      # @param [Hash] json framed JSON-LD
      # @return [Array<Manifest>]
      def self.from_jsonld(json)
        json['@graph'].map {|e| Manifest.new(e)}
      end

      def entries
        # Map entries to resources
        attributes['entries'].map {|e| Entry.new(e)}
      end
    end
 
    class Entry < JSON::LD::Resource
      attr_accessor :debug

      def base
        BASE + action.split('/').last
      end

      # Alias data and query
      def input
        @input ||= RDF::Util::File.open_file(action) {|f| f.read}
      end

      def expected
        @expected ||= RDF::Util::File.open_file(result) {|f| f.read}
      end
      
      def evaluate?
        attributes['@type'].include?("To")
      end
      
      def sparql?
        attributes['@type'].include?("Sparql")
      end

      def rdf?
        attributes['@type'].include?("Rdf")
      end

      def json?
        attributes['@type'].include?("Json")
      end

      def syntax?
        attributes['@type'].include?("Syntax")
      end

      def positive_test?
        !negative_test?
      end
      
      def negative_test?
        attributes['@type'].include?("Negative")
      end
    end
  end
end