# frozen_string_literal: true

require "json"
require "kettle/ndjson"
require "open3"
require "optparse"
require "yaml"

module Kettle
  module Deps
    module Floor
      # Command-line entry point shared by the generic executable and project
      # compatibility wrappers such as kettle-jem-deps-floor.
      class CLI
        DEFAULT_UPGRADE = "major"

        def self.run(argv = ARGV, out: $stdout, err: $stderr, defaults: {})
          options = parse_options(argv, defaults: defaults)
          if options[:help]
            out.puts(parser(defaults: defaults))
            return 0
          end
          if options[:events] && options[:json]
            raise OptionParser::InvalidOption, "--events cannot be combined with --json"
          end
          config = load_config(options.fetch(:config_path))
          sources = options.fetch(:sources).empty? ? Array(config["sources"] || defaults[:sources] || ["*.gemspec"]) : options.fetch(:sources)
          target_versions = config.fetch("target_versions", {}).merge(options.fetch(:target_versions))
          holds = config.fetch("holds", {})
          event_types = %w[run_start command_step summary]
          events = Kettle::Ndjson.event_stream(out, types: event_types.join(","), event_types: event_types) if options[:events]
          Kettle::Ndjson.emit_event(events, "run_start", command: "kettle-deps-floor", project_root: options.fetch(:project_root))
          updater_options = {
            project_root: options.fetch(:project_root),
            sources: sources,
            target_versions: target_versions,
            upgrade: options.fetch(:upgrade),
            gem_names: options.fetch(:gem_names),
            holds: holds
          }
          planned = Updater.new(**updater_options).run

          if options[:write] && options[:commit] && planned.fetch(:updates).positive?
            paths = planned.fetch(:planned_changes).map { |change| change.fetch(:relative_path) }.uniq
            paths << "CHANGELOG.md" if options[:changelog]
            dirty = dirty_paths(options.fetch(:project_root), paths)
            raise "Refusing to commit because target files were already dirty: #{dirty.join(", ")}" unless dirty.empty?
          end

          result = if options[:write]
            Updater.new(**updater_options, write: true).run
          else
            planned
          end
          emit_dependency_floor_events(events, result, write: options[:write])
          changelog_result = write_changelog(options, config, result, defaults) if options[:write] && options[:changelog] && result.fetch(:updates).positive?
          commit_result = commit_changes(options, result, changelog_result) if options[:write] && options[:commit] && result.fetch(:updates).positive?
          print_result(options[:events] ? err : out, result, commit_result, changelog_result, json: options[:json])
          return 1 if options[:check] && result.fetch(:updates).positive?

          0
        rescue OptionParser::ParseError, ArgumentError => error
          err.puts(error.message)
          err.puts(parser(defaults: defaults))
          2
        rescue => error
          err.puts("#{error.class}: #{error.message}")
          1
        end

        def self.parse_options(argv, defaults: {})
          options = {
            project_root: File.expand_path(defaults.fetch(:project_root, Dir.pwd)),
            config_path: nil,
            sources: [],
            target_versions: {},
            gem_names: [],
            upgrade: DEFAULT_UPGRADE,
            write: false,
            check: false,
            commit: true,
            changelog: true,
            json: false,
            events: false
          }
          parser(defaults: defaults, options: options).parse!(argv, into: options)
          options[:project_root] = File.expand_path(argv.shift || options.fetch(:project_root))
          raise OptionParser::InvalidArgument, "Expected at most one PROJECT_ROOT" unless argv.empty?

          options[:config_path] ||= File.join(options.fetch(:project_root), defaults.fetch(:config_name, ".kettle-deps-floor.yml"))
          options
        end

        def self.parser(defaults: {}, options: {})
          OptionParser.new do |opts|
            opts.banner = "Usage: #{defaults.fetch(:executable, "kettle-deps-floor")} [PROJECT_ROOT] [options]"
            opts.on("--source GLOB", "Ruby source glob to scan; may be repeated.") { |value| options[:sources] << value }
            opts.on("--target GEM=VERSION", "Set a family/release target version; may be repeated.") do |value|
              name, version = value.split("=", 2)
              raise OptionParser::InvalidArgument, "Expected GEM=VERSION, got #{value.inspect}" if name.to_s.empty? || version.to_s.empty?

              options[:target_versions][name] = version
            end
            opts.on("--only GEMS", "Limit updates to comma-separated gem names.") { |value| options[:gem_names].concat(value.split(",").map(&:strip)) }
            opts.on("--upgrade LEVEL", "Upgrade strategy: major, minor, patch (default: #{DEFAULT_UPGRADE}).") { |value| options[:upgrade] = value }
            opts.on("-w", "--write", "Write dependency floor updates.") { options[:write] = true }
            opts.on("--check", "Exit 1 when updates are available, without writing.") { options[:check] = true }
            opts.on("--[no-]commit", "Commit the changed files when writing (default: true).") { |value| options[:commit] = value }
            opts.on("--[no-]changelog", "Upsert an Unreleased changelog entry when writing (default: true).") { |value| options[:changelog] = value }
            opts.on("--config PATH", "Read additional sources and holds from YAML.") { |value| options[:config_path] = File.expand_path(value) }
            opts.on("--json", "Print a machine-readable JSON report.") { options[:json] = true }
            opts.on("--events", "Emit compact NDJSON progress events to stdout; send the human report to stderr.") { options[:events] = true }
            opts.on("-h", "--help", "Print this help.") { options[:help] = true }
          end
        end

        def self.load_config(path)
          return {} unless File.file?(path)

          config = YAML.safe_load_file(path, permitted_classes: [], aliases: false) || {}
          raise ArgumentError, "#{path} must contain a mapping" unless config.is_a?(Hash)

          config
        end

        def self.write_changelog(options, config, result, defaults)
          key = config.fetch("changelog_key", defaults.fetch(:changelog_key, "kettle-deps-floor"))
          details = result.fetch(:planned_changes).group_by { |change| change.fetch(:name) }.map do |name, changes|
            initial = changes.map { |change| Gem::Version.new(change.fetch(:current_floor)) }.min
            latest = changes.map { |change| Gem::Version.new(change.fetch(:new_floor)) }.max
            "  - #{name} (>= #{initial} -> >= #{latest})"
          end
          label = config.fetch("changelog_entry", defaults.fetch(:changelog_entry, "Update dependency floors:"))
          entry = ([label] + details).join("\n")
          command = ["kettle-changelog", "--upsert-unreleased-entry", "--section", "Changed", "--key", key, "--entry", entry]
          stdout, stderr, status = Open3.capture3(*command, chdir: options.fetch(:project_root))
          raise "kettle-changelog failed: #{stderr.empty? ? stdout : stderr}" unless status.success?

          {status: "updated", output: stdout.strip}
        end

        def self.dirty_paths(root, paths)
          return [] unless git(root, "rev-parse", "--show-toplevel", allow_failure: true)

          git(root, "status", "--porcelain", "--", *paths).lines.map { |line| line[3..].to_s.strip }
        end

        def self.commit_changes(options, result, changelog_result)
          root = options.fetch(:project_root)
          relative_paths = result.fetch(:planned_changes).map { |change| change.fetch(:relative_path) }.uniq
          relative_paths << "CHANGELOG.md" if changelog_result
          relative_paths.uniq!
          top = git(root, "rev-parse", "--show-toplevel", allow_failure: true)
          return {status: "unavailable", reason: "not_git_repository"} unless top

          changed = relative_paths.select { |path| File.file?(File.join(root, path)) }
          return {status: "clean_noop"} if changed.empty?

          git(root, "add", "--", *changed)
          git(root, "commit", "-m", defaults_commit_message(result))
          {status: "committed", files: changed}
        end

        def self.defaults_commit_message(result)
          names = result.fetch(:updated_dependencies)
          "⬆️ Raise dependency floors: #{names.join(", ")}"
        end

        def self.git(root, *args, allow_failure: false)
          stdout, stderr, status = Open3.capture3("git", *args, chdir: root)
          return stdout if status.success?
          return nil if allow_failure

          raise "git #{args.join(" ")} failed: #{stderr.empty? ? stdout : stderr}"
        end

        def self.emit_dependency_floor_events(events, result, write:)
          return unless events

          result.fetch(:planned_changes).each_with_index do |change, index|
            Kettle::Ndjson.emit_event(
              events,
              "command_step",
              phase: "dependency_floor",
              name: "raise_floor",
              status: write ? "updated" : "planned",
              index: index + 1,
              total: result.fetch(:planned_changes).length,
              gem_name: change.fetch(:name),
              path: change.fetch(:relative_path),
              current_floor: change.fetch(:current_floor),
              new_floor: change.fetch(:new_floor)
            )
          end
          status = if write
            "updated"
          else
            "planned"
          end
          status = "ok" unless result.fetch(:updates).positive?
          Kettle::Ndjson.emit_summary_event(
            events,
            command: "kettle-deps-floor",
            status: status,
            updates: result.fetch(:updates),
            updated_dependencies: result.fetch(:updated_dependencies)
          )
        end

        def self.print_result(out, result, commit_result, changelog_result, json:)
          if json
            out.puts(JSON.pretty_generate(result.merge(commit: commit_result, changelog: changelog_result)))
            return
          end

          out.puts("deps-floor: mode=#{result.fetch(:mode)} upgrade=#{result.fetch(:upgrade)}")
          out.puts("deps-floor: #{result.fetch(:updates)} update#{"s" unless result.fetch(:updates) == 1}")
          result.fetch(:planned_changes).each do |change|
            out.puts("  #{change.fetch(:name)} #{change.fetch(:relative_path)} >= #{change.fetch(:current_floor)} -> >= #{change.fetch(:new_floor)}")
          end
          out.puts("changelog: #{changelog_result.fetch(:status)}") if changelog_result
          out.puts("commit: #{commit_result.fetch(:status)}") if commit_result
          if result.fetch(:mode) == "dry-run" && result.fetch(:updates).positive?
            out.puts("hint: rerun with --write --upgrade #{result.fetch(:upgrade)} to apply updates")
          end
        end

        private_class_method :parser
      end
    end
  end
end
