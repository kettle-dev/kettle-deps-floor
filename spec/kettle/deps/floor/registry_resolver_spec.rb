# frozen_string_literal: true

RSpec.describe Kettle::Deps::Floor::RegistryResolver do
  it "filters prerelease and out-of-range versions from the shared RubyGems cache response" do
    allow(Kettle::Dev::RubyGemsVersions).to receive(:fetch).with("example-gem").and_return([
      {"number" => "1.2.1"},
      {"number" => "1.2.9"},
      {"number" => "1.3.0"},
      {"number" => "1.3.0.pre", "prerelease" => true},
      {"number" => ""}
    ])

    versions = described_class.new.versions("example-gem", requirements: [">= 1.2.1", "~> 1.2.0"])

    expect(versions).to eq([{number: "1.2.1"}, {number: "1.2.9"}])
  end

  it "returns only stable registry entries when no upgrade bounds are supplied" do
    allow(Kettle::Dev::RubyGemsVersions).to receive(:fetch).with("example-gem").and_return([
      {"number" => "1.0.0"},
      {"number" => "1.1.0.pre", "prerelease" => true}
    ])

    expect(described_class.new.versions("example-gem")).to eq([{number: "1.0.0"}])
  end
end
