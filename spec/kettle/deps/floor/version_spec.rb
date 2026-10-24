# frozen_string_literal: true

require "anonymous_loader"
require "kettle/deps/floor"
RSpec.describe Kettle::Deps::Floor::Version do
  it_behaves_like "a Version module", described_class

  it "executes the version file for coverage without redefining constants" do
    dir = File.expand_path("../../../../lib/kettle/deps/floor", __dir__)
    paths = %w[version.rb version_gem.rb].map { |file| File.join(dir, file) }.select { |path| File.file?(path) }
    anonymous_namespace = AnonymousLoader.load(files: paths)

    expect(anonymous_namespace::Kettle::Deps::Floor::Version::VERSION).to eq(described_class::VERSION)
  end
end
