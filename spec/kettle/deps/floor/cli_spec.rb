# frozen_string_literal: true

require "stringio"
require "tmpdir"
require "fileutils"

RSpec.describe Kettle::Deps::Floor::CLI do
  around do |example|
    Dir.mktmpdir("kettle-deps-floor-cli") do |root|
      @root = root
      example.run
    end
  end

  it "prints help and returns success" do
    out = StringIO.new
    err = StringIO.new

    status = described_class.run(["--help"], out: out, err: err)

    expect(status).to eq(0)
    expect(out.string).to include("Usage: kettle-deps-floor", "--upgrade LEVEL")
    expect(err.string).to eq("")
  end

  it "writes explicit targets without changelog or commit when opted out" do
    gemspec = File.join(@root, "example.gemspec")
    File.write(gemspec, %(spec.add_dependency("token-resolver", "~> 2.0", ">= 2.0.4")\n))
    out = StringIO.new
    err = StringIO.new

    status = described_class.run(
      ["--write", "--no-commit", "--no-changelog", "--target", "token-resolver=2.0.14", "--source", "*.gemspec", @root],
      out: out,
      err: err
    )

    expect(status).to eq(0)
    expect(File.read(gemspec)).to include(">= 2.0.14")
    expect(out.string).to include("mode=write", "token-resolver")
    expect(err.string).to eq("")
  end

  it "upserts a changelog entry when writing and preserves the generated report" do
    gemspec = File.join(@root, "example.gemspec")
    File.write(gemspec, %(spec.add_dependency("token-resolver", "~> 2.0", ">= 2.0.4")\n))
    changelog = File.join(@root, "CHANGELOG.md")
    File.write(changelog, "## [Unreleased]\n\n### Changed\n\n")
    allow(Open3).to receive(:capture3).and_return(["entry updated\n", "", instance_double(Process::Status, success?: true)])
    out = StringIO.new
    err = StringIO.new

    status = described_class.run(
      ["--write", "--no-commit", "--target", "token-resolver=2.0.14", "--source", "*.gemspec", @root],
      out: out,
      err: err
    )

    expect(status).to eq(0)
    expect(Open3).to have_received(:capture3).with(
      "kettle-changelog", "--upsert-unreleased-entry", "--section", "Changed", "--key", "kettle-deps-floor",
      "--entry", "Update dependency floors:\n  - token-resolver (>= 2.0.4 -> >= 2.0.14)", chdir: @root
    )
    expect(out.string).to include("changelog: updated")
    expect(err.string).to eq("")
  end

  it "commits a clean update when commit is enabled" do
    gemspec = File.join(@root, "example.gemspec")
    File.write(gemspec, %(spec.add_dependency("token-resolver", "~> 2.0", ">= 2.0.4")\n))
    system("git", "init", "-b", "main", chdir: @root, out: File::NULL, err: File::NULL)
    system("git", "config", "user.name", "Spec User", chdir: @root)
    system("git", "config", "user.email", "spec@example.com", chdir: @root)
    system("git", "config", "commit.gpgsign", "false", chdir: @root)
    system("git", "add", "example.gemspec", chdir: @root)
    system("git", "commit", "-m", "initial", chdir: @root, out: File::NULL)
    out = StringIO.new
    err = StringIO.new

    status = described_class.run(
      ["--write", "--no-changelog", "--target", "token-resolver=2.0.14", @root],
      out: out,
      err: err
    )

    expect(status).to eq(0)
    expect(out.string).to include("commit: committed")
    expect(err.string).to eq("")
    expect(`git -C #{@root} log -1 --format=%s`.strip).to eq("⬆️ Raise dependency floors: token-resolver")
  end

  it "reports updates but skips git commits outside a repository" do
    gemspec = File.join(@root, "example.gemspec")
    File.write(gemspec, %(spec.add_dependency("token-resolver", "~> 2.0", ">= 2.0.4")\n))
    out = StringIO.new
    err = StringIO.new

    status = described_class.run(
      ["--write", "--no-changelog", "--target", "token-resolver=2.0.14", @root],
      out: out,
      err: err
    )

    expect(status).to eq(0)
    expect(File.read(gemspec)).to include(">= 2.0.14")
    expect(out.string).to include("commit: unavailable")
    expect(err.string).to eq("")
  end

  it "refuses to commit when an update target was already dirty" do
    gemspec = File.join(@root, "example.gemspec")
    File.write(gemspec, %(spec.add_dependency("token-resolver", "~> 2.0", ">= 2.0.4")\n))
    system("git", "init", "-b", "main", chdir: @root, out: File::NULL, err: File::NULL)
    system("git", "config", "user.name", "Spec User", chdir: @root)
    system("git", "config", "user.email", "spec@example.com", chdir: @root)
    system("git", "add", "example.gemspec", chdir: @root)
    system("git", "commit", "-m", "initial", chdir: @root, out: File::NULL)
    File.write(gemspec, %(spec.add_dependency("token-resolver", "~> 2.0", ">= 2.0.5")\n))
    dirty_content = File.read(gemspec)
    out = StringIO.new
    err = StringIO.new

    status = described_class.run(
      ["--write", "--no-changelog", "--target", "token-resolver=2.0.14", @root],
      out: out,
      err: err
    )

    expect(status).to eq(1)
    expect(err.string).to include("already dirty")
    expect(File.read(gemspec)).to eq(dirty_content)
  end

  it "rejects a non-mapping configuration file" do
    File.write(File.join(@root, "broken.yml"), "not a mapping\n")
    out = StringIO.new
    err = StringIO.new

    status = described_class.run(["--config", File.join(@root, "broken.yml"), @root], out: out, err: err)

    expect(status).to eq(2)
    expect(err.string).to include("must contain a mapping")
  end

  it "returns success from check mode when configured floors are current" do
    gemspec = File.join(@root, "example.gemspec")
    File.write(gemspec, %(spec.add_dependency("token-resolver", "~> 2.0", ">= 2.0.14")\n))
    out = StringIO.new
    err = StringIO.new

    status = described_class.run(
      ["--check", "--target", "token-resolver=2.0.14", @root],
      out: out,
      err: err
    )

    expect(status).to eq(0)
    expect(out.string).to include("deps-floor: 0 updates")
    expect(err.string).to eq("")
  end

  it "prints machine-readable JSON when requested" do
    gemspec = File.join(@root, "example.gemspec")
    File.write(gemspec, %(spec.add_dependency("token-resolver", "~> 2.0", ">= 2.0.4")\n))
    out = StringIO.new
    err = StringIO.new

    status = described_class.run(
      ["--json", "--target", "token-resolver=2.0.14", @root],
      out: out,
      err: err
    )

    report = JSON.parse(out.string)
    expect(status).to eq(0)
    expect(report.fetch("planned_changes").first).to include("name" => "token-resolver", "new_floor" => "2.0.14")
    expect(err.string).to eq("")
  end

  it "reports stale explicit targets in check mode without writing" do
    gemspec = File.join(@root, "example.gemspec")
    original = <<~RUBY
      Gem::Specification.new do |spec|
        spec.add_dependency("token-resolver", "~> 2.0", ">= 2.0.4")
      end
    RUBY
    File.write(gemspec, original)
    File.write(File.join(@root, ".kettle-deps-floor.yml"), <<~YAML)
      sources:
        - "*.gemspec"
      target_versions:
        token-resolver: 2.0.14
    YAML
    out = StringIO.new
    err = StringIO.new

    status = described_class.run(["--check", @root], out: out, err: err)

    expect(status).to eq(1)
    expect(out.string).to include("token-resolver", ">= 2.0.4 -> >= 2.0.14")
    expect(err.string).to eq("")
    expect(File.read(gemspec)).to eq(original)
  end
end
