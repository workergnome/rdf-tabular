$:.unshift(File.join(File.dirname(__FILE__), '..', 'lib'))
$:.unshift File.dirname(__FILE__)

require "bundler/setup"
require 'rspec'
require 'rspec/its'
require 'rdf/isomorphic'
require 'rdf/tabular'
require 'rdf/turtle'
require 'rdf/spec/matchers'
require 'json'
require 'webmock/rspec'
require 'matchers'
require 'suite_helper'
require 'simplecov'
SimpleCov.start

WebMock.allow_net_connect!(net_http_connect_on_start: true)

JSON_STATE = JSON::State.new(
  :indent       => "  ",
  :space        => " ",
  :space_before => "",
  :object_nl    => "\n",
  :array_nl     => "\n"
)

::RSpec.configure do |c|
  c.filter_run focus:  true
  c.run_all_when_everything_filtered = true
  c.include(RDF::Spec::Matchers)
end

# Heuristically detect the input stream
def detect_format(stream)
  # Got to look into the file to see
  if stream.is_a?(IO) || stream.is_a?(StringIO)
    stream.rewind
    string = stream.read(1000)
    stream.rewind
  else
    string = stream.to_s
  end
  case string
  when /<html/i   then RDF::Microdatea::Reader
  when /@prefix/i then RDF::Turtle::Reader
  else                 RDF::Turtle::Reader
  end
end
