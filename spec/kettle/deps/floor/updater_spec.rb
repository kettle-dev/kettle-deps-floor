# frozen_string_literal: true

require "tmpdir"
require "fileutils"

RSpec.describe Kettle::Deps::Floor::Updater do
  around do |example|
    Dir.mktmpdir("kettle-deps-floor") do |root|
      @root = root
      example.run
    end
  end

  it "raises gemspec runtime and development dependency floors to explicit family versions" do
    gemspec = File.join(@root, "example.gemspec")
    File.write(gemspec, <<~RUBY)
      Gem::Specification.new do |spec|
        spec.add_dependency("token-resolver", "~> 2.0", ">= 2.0.4")
        spec.add_development_dependency("kettle-family", "~> 1.2", ">= 1.2.0")
      end
    RUBY

    result = described_class.new(
      project_root: @root,
      sources: ["*.gemspec"],
      target_versions: {"token-resolver" => "2.0.14", "kettle-family" => "1.3.33"},
      write: true
    ).run

    expect(result.fetch(:updates)).to eq(2)
    expect(File.read(gemspec)).to include(
      'spec.add_dependency("token-resolver", "~> 2.0", ">= 2.0.14")',
      'spec.add_development_dependency("kettle-family", "~> 1.2", ">= 1.3.33")'
    )
  end

  it "does not raise a floor to an explicit target excluded by another constraint" do
    gemspec = File.join(@root, "example.gemspec")
    original = <<~RUBY
      Gem::Specification.new do |spec|
        spec.add_dependency("faraday", ">= 0.17.3", "< 4.0")
      end
    RUBY
    File.write(gemspec, original)

    result = described_class.new(
      project_root: @root,
      sources: ["*.gemspec"],
      target_versions: {"faraday" => "4.0.0"}
    ).run

    expect(result.fetch(:updates)).to eq(0)
    expect(File.read(gemspec)).to eq(original)
  end

  it "filters unresolved target entries by selected gem name" do
    gemspec = File.join(@root, "example.gemspec")
    File.write(gemspec, <<~RUBY)
      Gem::Specification.new do |spec|
        spec.add_dependency("alpha", ">= 1.0.0")
        spec.add_dependency("beta", ">= 2.0.0")
      end
    RUBY

    result = described_class.new(
      project_root: @root,
      sources: ["*.gemspec"],
      target_versions: {"alpha" => "1.1.0", "beta" => "2.1.0"},
      gem_names: ["beta"]
    ).run

    expect(result.fetch(:discovered_dependencies)).to eq(["beta"])
    expect(result.fetch(:updated_dependencies)).to eq(["beta"])
  end

  it "ignores malformed floor requirements and declarations without an explicit floor" do
    gemspec = File.join(@root, "example.gemspec")
    File.write(gemspec, <<~RUBY)
      Gem::Specification.new do |spec|
        spec.add_dependency("malformed", ">= definitely-not-a-version")
        spec.add_dependency("no-floor", "~> 1.0")
      end
    RUBY

    result = described_class.new(
      project_root: @root,
      sources: ["*.gemspec"],
      target_versions: {"malformed" => "2.0.0", "no-floor" => "2.0.0"}
    ).run

    expect(result.fetch(:discovered_dependencies)).to be_empty
    expect(result.fetch(:updates)).to eq(0)
  end

  it "updates local Gemfile declarations and nomono floor assignments" do
    gemfile = File.join(@root, "Gemfile")
    File.write(gemfile, <<~RUBY)
      gem "kettle-dev", "~> 3.1", ">= 3.1.20"
      nomono_activation_requirements = ["~> 1.1", ">= 1.1.10"]
    RUBY

    result = described_class.new(
      project_root: @root,
      sources: ["Gemfile"],
      target_versions: {"kettle-dev" => "3.1.25", "nomono" => "1.1.15"},
      write: true
    ).run

    expect(result.fetch(:updates)).to eq(2)
    expect(File.read(gemfile)).to include(
      'gem "kettle-dev", "~> 3.1", ">= 3.1.25"',
      'nomono_activation_requirements = ["~> 1.1", ">= 1.1.15"]'
    )
  end

  it "ignores comments and dynamic dependency names" do
    gemspec = File.join(@root, "example.gemspec")
    File.write(gemspec, <<~RUBY)
      Gem::Specification.new do |spec|
        dependency_name = "ignored"
        # spec.add_dependency("commented", "~> 1.0", ">= 1.0.0")
        spec.add_dependency(dependency_name, "~> 1.0", ">= 1.0.0")
      end
    RUBY

    result = described_class.new(
      project_root: @root,
      sources: ["*.gemspec"],
      target_versions: {"ignored" => "1.1.0", "commented" => "1.1.0"}
    ).run

    expect(result.fetch(:discovered_dependencies)).to be_empty
  end

  it "rejects invalid upgrade levels" do
    updater = described_class.new(project_root: @root, upgrade: "fast")

    expect { updater.run }.to raise_error(ArgumentError, /Invalid upgrade level/)
  end

  it "discovers dependency names without needing registry access" do
    File.write(File.join(@root, "example.gemspec"), <<~RUBY)
      spec.add_dependency("alpha", ">= 1.0.0")
      spec.add_development_dependency("beta", ">= 2.0.0")
    RUBY

    expect(described_class.dependency_names(project_root: @root, sources: ["*.gemspec"])).to contain_exactly("alpha", "beta")
  end

  it "does not plan dependencies configured as holds" do
    gemspec = File.join(@root, "example.gemspec")
    File.write(gemspec, %(spec.add_dependency("rubocop-minitest", "~> 0.40", ">= 0.40.0")\n))

    result = described_class.new(
      project_root: @root,
      sources: ["*.gemspec"],
      target_versions: {"rubocop-minitest" => "0.41.0"},
      holds: {"rubocop-minitest" => "wait for compatible standard release"}
    ).run

    expect(result.fetch(:discovered_dependencies)).to eq(["rubocop-minitest"])
    expect(result.fetch(:updates)).to eq(0)
  end

  it "ignores a target when the existing requirement is malformed" do
    gemspec = File.join(@root, "example.gemspec")
    File.write(gemspec, %(spec.add_dependency("example", "not-a-requirement", ">= 1.0.0")\n))

    result = described_class.new(
      project_root: @root,
      sources: ["*.gemspec"],
      target_versions: {"example" => "1.1.0"}
    ).run

    expect(result.fetch(:updates)).to eq(0)
  end

  it "discovers floors in the template managed dependency registry" do
    File.write(File.join(@root, "registry.rb"), <<~RUBY)
      TEMPLATE_MANAGED_DEPENDENCIES = [{name: "registry-gem", requirements: ["~> 1.0", ">= 1.0.2"]}].freeze
    RUBY

    result = described_class.new(project_root: @root, sources: ["*.rb"], target_versions: {"registry-gem" => "1.0.5"}).run

    expect(result.fetch(:discovered_dependencies)).to eq(["registry-gem"])
  end

  it "raises floors and compatible pessimistic bounds in the template dependency registry" do
    registry = File.join(@root, "registry.rb")
    original = <<~RUBY
      TEMPLATE_MANAGED_DEPENDENCIES = [
        {name: "registry-gem", requirements: ["~> 1.0", ">= 1.0.2"]}
      ].freeze
    RUBY
    File.write(registry, original)
    resolver = instance_double(Kettle::Deps::Floor::RegistryResolver)
    allow(resolver).to receive(:versions).and_return([{number: "1.0.2"}, {number: "1.1.0"}])

    result = described_class.new(project_root: @root, sources: ["*.rb"], resolver: resolver, upgrade: "minor", write: true).run

    expect(result.fetch(:updates)).to eq(1)
    expect(File.read(registry)).to include('{name: "registry-gem", requirements: ["~> 1.1", ">= 1.1.0"]}')
  end

  it "discovers floors in the gemspec minimum requirement registry" do
    File.write(File.join(@root, "registry.rb"), <<~RUBY)
      GEMSPEC_DEPENDENCY_MINIMUM_REQUIREMENTS = {"minimum-gem" => ">= 2.0.1"}.freeze
    RUBY

    result = described_class.new(project_root: @root, sources: ["*.rb"], target_versions: {"minimum-gem" => "2.0.3"}, write: true).run

    expect(result.fetch(:discovered_dependencies)).to eq(["minimum-gem"])
    expect(File.read(File.join(@root, "registry.rb"))).to include('"minimum-gem" => ">= 2.0.3"')
  end

  it "discovers dependency floors embedded in template text snippets" do
    template = File.join(@root, "template.example")
    original = %(%(gem "embedded-gem", "~> 3.0", ">= 3.0.1")\n)
    File.write(template, original)

    result = described_class.new(
      project_root: @root,
      sources: ["*.example"],
      target_versions: {"embedded-gem" => "3.0.4"},
      write: true
    ).run

    expect(result.fetch(:discovered_dependencies)).to eq(["embedded-gem"])
    expect(File.read(template)).to include('"~> 3.0", ">= 3.0.4"')
  end

  it "raises a floor without inventing a pessimistic constraint" do
    gemspec = File.join(@root, "example.gemspec")
    File.write(gemspec, %(spec.add_dependency("token-resolver", ">= 2.0.4")\n))

    result = described_class.new(
      project_root: @root,
      sources: ["*.gemspec"],
      target_versions: {"token-resolver" => "2.0.14"},
      write: true
    ).run

    expect(result.fetch(:updates)).to eq(1)
    expect(File.read(gemspec)).to include('spec.add_dependency("token-resolver", ">= 2.0.14")')
    expect(File.read(gemspec)).not_to include("~>")
  end

  it "does not plan when the registry has no compatible newer versions" do
    gemspec = File.join(@root, "example.gemspec")
    File.write(gemspec, %(spec.add_dependency("example", "~> 1.0", ">= 1.0.1")\n))
    resolver = instance_double(Kettle::Deps::Floor::RegistryResolver, versions: [])

    result = described_class.new(project_root: @root, sources: ["*.gemspec"], resolver: resolver).run

    expect(result.fetch(:updates)).to eq(0)
    expect(result.fetch(:discovered_dependencies)).to eq(["example"])
  end

  it "discovers and plans registry floors without changing files" do
    gemspec = File.join(@root, "example.gemspec")
    original = <<~RUBY
      Gem::Specification.new do |spec|
        spec.add_dependency("example-runtime", "~> 1.0", ">= 1.0.1")
      end
    RUBY
    File.write(gemspec, original)
    resolver = instance_double(Kettle::Deps::Floor::RegistryResolver)
    allow(resolver).to receive(:versions) do |_name, requirements:|
      allowed = Gem::Requirement.new(*requirements)
      [{"number" => "1.0.1"}, {"number" => "1.0.9"}, {"number" => "1.1.0"}].select do |entry|
        allowed.satisfied_by?(Gem::Version.new(entry.fetch("number")))
      end
    end

    result = described_class.new(
      project_root: @root,
      sources: ["*.gemspec"],
      resolver: resolver,
      upgrade: "patch"
    ).run

    expect(result.fetch(:updates)).to eq(1)
    expect(result.fetch(:planned_changes).first).to include(name: "example-runtime", new_floor: "1.0.9")
    expect(File.read(gemspec)).to eq(original)
  end
end
