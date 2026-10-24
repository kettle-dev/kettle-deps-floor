# frozen_string_literal: true

require "fileutils"
require "pathname"
require "rubygems"
require "kettle/dev"

module Kettle
  module Deps
    module Floor
      # Finds explicit lower-bound dependency requirements in configured Ruby
      # sources and raises them either to a supplied family version or to a
      # registry version bounded by the selected upgrade level.
      class Updater
        DEPENDENCY_METHODS = %i[add_dependency add_runtime_dependency add_development_dependency].freeze
        GEMFILE_METHODS = %i[gem].freeze
        ASSIGNMENT_NAMES = %i[nomono_requirements nomono_activation_requirements].freeze
        VALID_UPGRADES = %w[major minor patch].freeze

        def initialize(project_root:, sources: ["*.gemspec"], resolver: RegistryResolver.new, target_versions: {},
          upgrade: "major", write: false, check: false, gem_names: nil, holds: {}, registry_updates: true,
          placeholder_pattern: nil)
          @project_root = File.expand_path(project_root)
          @sources = Array(sources).map(&:to_s)
          @resolver = resolver
          @target_versions = target_versions.transform_keys(&:to_s).transform_values { |value| Gem::Version.new(value.to_s) }
          @upgrade = upgrade.to_s
          @write = write
          @check = check
          @gem_names = Array(gem_names).map(&:to_s)
          @holds = holds.transform_keys(&:to_s)
          @registry_updates = registry_updates
          @placeholder_pattern = placeholder_pattern && Regexp.new(placeholder_pattern.to_s)
        end

        attr_reader :project_root, :sources, :resolver, :target_versions, :upgrade, :gem_names, :holds, :registry_updates, :placeholder_pattern

        def self.dependency_names(project_root:, sources:)
          new(project_root: project_root, sources: sources).dependencies
        end

        def dependencies
          dependency_records.map { |record| record.fetch(:name) }.uniq
        end

        def run
          validate_options!
          records = dependency_records
          planned_changes = records.filter_map { |record| plan_record(record) }
          apply_changes(planned_changes) if @write
          {
            mode: @write ? "write" : "dry-run",
            check: !!@check,
            upgrade: upgrade,
            discovered_dependencies: records.map { |record| record.fetch(:name) }.uniq.sort,
            updates: planned_changes.length,
            updated_dependencies: planned_changes.map { |change| change.fetch(:name) }.uniq.sort,
            planned_changes: planned_changes.map { |change| serializable_change(change) }
          }
        end

        private

        def validate_options!
          return if VALID_UPGRADES.include?(upgrade)

          raise ArgumentError, "Invalid upgrade level #{upgrade.inspect}; use one of: #{VALID_UPGRADES.join(", ")}"
        end

        def dependency_records
          source_paths.flat_map { |relative_path| records_for_path(relative_path) }.uniq do |record|
            [record.fetch(:relative_path), record.fetch(:name), record.fetch(:floor_range).fetch(:start_offset)]
          end
        end

        def source_paths
          sources.flat_map do |pattern|
            Dir.glob(File.join(project_root, pattern), File::FNM_DOTMATCH).select { |path| File.file?(path) }
          end.uniq.sort.map { |path| relative_path(path) }
        end

        def relative_path(path)
          Pathname(path).relative_path_from(Pathname(project_root)).to_s
        end

        def records_for_path(relative_path)
          path = File.join(project_root, relative_path)
          source = File.read(path)
          spans = placeholder_spans(source)
          parse_result = Kettle::Dev::VersionBump.parse_source(spans.empty? ? source : sanitize_placeholders(source, spans), path)
          nodes = Kettle::Dev::VersionBump.each_node(parse_result.value)
          records = nodes.flat_map do |node|
            [
              call_record(node, source, relative_path),
              assignment_record(node, source, relative_path),
              *Array(registry_records(node, source, relative_path))
            ].compact
          end + embedded_text_records(source, relative_path)
          return records if spans.empty?

          # Records whose floor or pessimistic requirement sits inside a
          # substituted placeholder span are not editable (the placeholder owns
          # those bytes), and names manufactured by the substitution sentinel
          # are not real gems.
          records.reject do |record|
            sentinel_name?(record.fetch(:name)) ||
              span_touched?(spans, record.fetch(:floor_range)) ||
              (record[:pessimistic_range] && span_touched?(spans, record.fetch(:pessimistic_range)))
          end
        rescue Kettle::Dev::Error => error
          raise Error, error.message
        end

        # Template placeholders such as kettle-jem's {KJ|TOKEN} are not valid
        # Ruby in code positions, which makes the whole source unparseable.
        # Each placeholder span is replaced with an equal-length constant token
        # so Prism offsets still map 1:1 onto the original bytes; a constant
        # parses in every position a placeholder occupies (statement, value,
        # argument, `::` namespace segment), and it never becomes a StringNode,
        # so substituted regions can never yield editable floor records.
        # A placeholder glued to a preceding closing token (`)`, `"`, `}`)
        # gets a `::`-prefixed constant instead, so e.g. `call("exe"){KJ|X}`
        # parses as a constant path; inside string literals either shape is
        # inert text.
        def placeholder_spans(source)
          return [] unless placeholder_pattern

          spans = []
          position = 0
          while (match = placeholder_pattern.match(source, position))
            spans << [match.begin(0), match.end(0)]
            position = match.end(0)
          end
          spans
        end

        def sanitize_placeholders(source, spans)
          sanitized = source.dup
          spans.each do |start_offset, end_offset|
            length = end_offset - start_offset
            previous = start_offset.zero? ? nil : sanitized[start_offset - 1]
            token = if previous && %[) " }].include?(previous) && length >= 3
              "::C" + ("x" * (length - 3))
            else
              "C" + ("x" * (length - 1))
            end
            sanitized[start_offset...end_offset] = token
          end
          sanitized
        end

        def sentinel_name?(name)
          name.match?(/\ACx{4,}\z/)
        end

        def span_touched?(spans, range)
          spans.any? { |start_offset, end_offset| range.fetch(:start_offset) < end_offset && start_offset < range.fetch(:end_offset) }
        end

        def call_record(node, source, relative_path)
          return unless node.is_a?(Prism::CallNode)
          dependency_call = DEPENDENCY_METHODS.include?(node.name)
          gemfile_call = node.receiver.nil? && GEMFILE_METHODS.include?(node.name)
          return if !dependency_call && !gemfile_call

          arguments = node.arguments&.arguments || []
          name_node = arguments.first
          return unless name_node.is_a?(Prism::StringNode)

          record_from_nodes(name_node.unescaped, arguments.drop(1), source, relative_path, "gemspec_or_gemfile")
        end

        def assignment_record(node, source, relative_path)
          return unless node.is_a?(Prism::LocalVariableWriteNode) && ASSIGNMENT_NAMES.include?(node.name)
          return unless node.value.is_a?(Prism::ArrayNode)

          record_from_nodes("nomono", node.value.elements, source, relative_path, "requirement_assignment")
        end

        # Registry entries are ordinary Ruby AST; only embedded examples need
        # text scanning because their %(...) delimiters are not valid Ruby.
        def registry_records(node, source, relative_path)
          return unless node.is_a?(Prism::ConstantWriteNode)
          registry = node.name
          value = node.value
          value = value.receiver if value.is_a?(Prism::CallNode) && value.name == :freeze
          case registry
          when :TEMPLATE_MANAGED_DEPENDENCIES
            return unless value.is_a?(Prism::ArrayNode)
            value.elements.filter_map do |entry|
              next unless entry.is_a?(Prism::HashNode)
              fields = entry.elements.to_h do |assoc|
                [assoc.key.unescaped.to_s, assoc.value] if assoc.is_a?(Prism::AssocNode) && assoc.key.is_a?(Prism::SymbolNode)
              end.compact
              name_node = fields["name"]
              name = name_node.unescaped if name_node.is_a?(Prism::StringNode)
              reqs = fields["requirements"]
              record_from_nodes(name, reqs.elements, source, relative_path, "template_registry") if reqs.is_a?(Prism::ArrayNode)
            end
          when :GEMSPEC_DEPENDENCY_MINIMUM_REQUIREMENTS
            return unless value.is_a?(Prism::HashNode)
            value.elements.filter_map do |assoc|
              next unless assoc.is_a?(Prism::AssocNode) && assoc.key.is_a?(Prism::StringNode) && assoc.value.is_a?(Prism::StringNode)
              record_from_nodes(assoc.key.unescaped, [assoc.value], source, relative_path, "gemspec_floor")
            end
          end
        end

        def embedded_text_records(source, relative_path)
          # Regex is intentionally limited to invalid-Ruby embedded template text;
          # Prism cannot expose dependency calls inside %(...) string contents.
          return [] unless source.include?("%(")

          pattern = /%\(gem\s+"([A-Za-z0-9_.-]+)"\s*,\s*"(~> [^"]+)"\s*,\s*"(>= [^"]+)"/
          # A position-loop with explicit MatchData: Regexp.last_match inside a
          # to_enum(:scan) block is unreliable on TruffleRuby.
          records = []
          position = 0
          while (match = pattern.match(source, position))
            position = match.end(0)
            pessimistic_offset = source[0...match.begin(2)].bytesize - 1
            floor_offset = source[0...match.begin(3)].bytesize - 1
            record = record_from_ranges(
              match[1],
              "embedded_template_text",
              source,
              relative_path,
              match[2],
              {start_offset: pessimistic_offset, end_offset: pessimistic_offset + match[2].bytesize + 2},
              match[3],
              {start_offset: floor_offset, end_offset: floor_offset + match[3].bytesize + 2},
              [match[2], match[3]]
            )
            records << record if record
          end
          records
        end

        def record_from_nodes(name, nodes, source, relative_path, source_kind)
          return unless name.is_a?(String) && name.match?(/\A[a-zA-Z0-9_.-]+\z/)
          return if !gem_names.empty? && !gem_names.include?(name)

          requirements = string_nodes(nodes)
          floor = requirements.find { |entry| entry.unescaped.start_with?(">=") }
          return unless floor

          pessimistic = requirements.find { |entry| entry.unescaped.start_with?("~>") }
          record_from_ranges(
            name,
            source_kind,
            source,
            relative_path,
            pessimistic&.unescaped,
            pessimistic && node_range(pessimistic),
            floor.unescaped,
            node_range(floor),
            requirements.map(&:unescaped)
          )
        end

        def record_from_ranges(name, source_kind, source, relative_path, pessimistic, pessimistic_range, floor, floor_range, requirements)
          return unless name.is_a?(String) && name.match?(/\A[a-zA-Z0-9_.-]+\z/)
          return if !gem_names.empty? && !gem_names.include?(name)

          {
            name: name,
            relative_path: relative_path,
            source_kind: source_kind,
            source: source,
            current_pessimistic: pessimistic,
            current_floor: floor_version(floor),
            pessimistic_range: pessimistic_range,
            floor_range: floor_range,
            requirements: requirements
          }
        rescue ArgumentError
          nil
        end

        def string_nodes(nodes)
          Array(nodes).flat_map do |node|
            case node
            when Prism::StringNode
              [node]
            when Prism::ArrayNode
              string_nodes(node.elements)
            else
              []
            end
          end
        end

        def floor_version(requirement)
          entry = Gem::Requirement.new(requirement).requirements.find { |operator, _version| operator == ">=" }
          raise ArgumentError, "Expected >= requirement, got #{requirement.inspect}" unless entry

          entry.last
        end

        def node_range(node)
          {start_offset: node.location.start_offset, end_offset: node.location.end_offset}
        end

        def plan_record(record)
          name = record.fetch(:name)
          return if holds.key?(name)

          current = record.fetch(:current_floor)
          target = target_versions[name]
          target ||= registry_target(record, current) if registry_updates
          return unless target && target > current
          return unless target_compatible?(record, target)

          new_pessimistic = if target_versions.key?(name) || !record[:pessimistic_range]
            nil
          else
            pessimistic_requirement_for(target)
          end
          record.merge(
            current_floor_version: current,
            new_floor_version: target,
            new_pessimistic: new_pessimistic
          )
        end

        def registry_target(record, current)
          requirements = requirements_for_upgrade(current)
          versions = resolver.versions(record.fetch(:name), requirements: requirements)
          Array(versions).filter_map do |entry|
            version = entry[:number] || entry["number"]
            Gem::Version.new(version.to_s) unless version.to_s.empty?
          end.max
        end

        def requirements_for_upgrade(current)
          major = current.segments.fetch(0)
          minor = current.segments.fetch(1, 0)
          case upgrade
          when "patch"
            [">= #{current}", "~> #{major}.#{minor}.0"]
          when "minor"
            [">= #{current}", "~> #{major}.0"]
          else
            [">= #{current}"]
          end
        end

        def target_compatible?(record, target)
          fixed_constraints = record.fetch(:requirements).reject { |requirement| requirement.start_with?(">=") }
          Gem::Requirement.new(*fixed_constraints).satisfied_by?(target)
        rescue ArgumentError
          false
        end

        def pessimistic_requirement_for(version)
          segments = version.segments
          "~> #{segments.fetch(0)}.#{segments.fetch(1, 0)}"
        end

        def apply_changes(changes)
          edits = changes.flat_map do |change|
            replacements = []
            if change[:new_pessimistic]
              replacements << edit(change, change.fetch(:pessimistic_range), change.fetch(:new_pessimistic))
            end
            replacements << edit(change, change.fetch(:floor_range), ">= #{change.fetch(:new_floor_version)}")
            replacements
          end
          Kettle::Dev::VersionBump.write_edits(edits)
        end

        def edit(change, range, value)
          source = change.fetch(:source)
          original = source.byteslice(range.fetch(:start_offset), range.fetch(:end_offset) - range.fetch(:start_offset))
          Kettle::Dev::VersionBump.file_edit(
            File.join(project_root, change.fetch(:relative_path)),
            source,
            range.fetch(:start_offset),
            range.fetch(:end_offset),
            Kettle::Dev::VersionBump.quote_like(original, value)
          )
        end

        def serializable_change(change)
          {
            name: change.fetch(:name),
            relative_path: change.fetch(:relative_path),
            source_kind: change.fetch(:source_kind),
            current_floor: change.fetch(:current_floor_version).to_s,
            new_floor: change.fetch(:new_floor_version).to_s,
            current_pessimistic: change[:current_pessimistic],
            new_pessimistic: change[:new_pessimistic]
          }
        end
      end
    end
  end
end
