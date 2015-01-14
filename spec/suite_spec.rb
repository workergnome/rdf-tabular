$:.unshift "."
require 'spec_helper'

describe RDF::Tabular::Reader do
  # W3C CSVW Test suite from FIXME
  describe "w3c csvw RDF tests" do
    require 'suite_helper'
    MANIFEST = Fixtures::SuiteTest::BASE + "manifest.ttl"

    Fixtures::SuiteTest::Manifest.open(MANIFEST) do |m|
      describe m.comment do
        m.entries.each do |t|
          specify "#{t.id.split("/").last}: #{t.name} - #{t.comment}" do
            t.debug = []
            RDF::Tabular::Reader.open(t.action,
              t.reader_options.merge(
                base_uri:        t.base,
                debug:           t.debug
              )
            ) do |reader|
              expect(reader).to be_a RDF::Reader

              graph = RDF::Repository.new

              if t.positive_test?
                if t.json?
                  result = reader.to_json
                  if t.evaluate?
                    RDF::Util::File.open_file(t.result) do |res|
                      expect(::JSON.parse(result)).to produce(::JSON.parse(res.read), t)
                    end
                  else
                    expect(::JSON.parse(result)).to be_a(Hash)
                  end
                else
                  begin
                    graph << reader
                  rescue Exception => e
                    expect(e.message).to produce("Not exception #{e.inspect}\n#{e.backtrace.join("\n")}", t.debug)
                  end

                  if t.sparql?
                    RDF::Util::File.open_file(t.result) do |query|
                      expect(graph).to pass_query(query, t)
                    end
                  elsif t.evaluate?
                    output_graph = RDF::Repository.load(t.result, format: :ttl, base_uri:  t.base)
                    expect(graph).to be_equivalent_graph(output_graph, t)
                  else
                    expect(graph).to be_a(RDF::Enumerable)
                  end
                end
              else
                expect {
                  graph << reader
                  expect(graph.dump(:ntriples)).to produce("not this", t.debug)
                }.to raise_error(RDF::ReaderError)
              end
            end
          end
        end
      end
    end
  end
end unless ENV['CI']  # Skip for continuous integration