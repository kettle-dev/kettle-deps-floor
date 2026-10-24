# frozen_string_literal: true

require "kettle/dev"

module Kettle
  module Deps
    module Floor
      # Registry adapter backed by kettle-dev's shared persistent RubyGems cache.
      class RegistryResolver
        def versions(gem_name, requirements: nil)
          Kettle::Dev::RubyGemsVersions.fetch(gem_name).filter_map do |entry|
            number = entry["number"] || entry[:number]
            next if number.to_s.empty?
            next if prerelease_entry?(entry, number)
            next if requirements && !Gem::Requirement.new(*requirements).satisfied_by?(Gem::Version.new(number.to_s))

            {number: number.to_s}
          end
        end

        private

        def prerelease_entry?(entry, number)
          prerelease = entry["prerelease"] || entry[:prerelease]
          explicitly_prerelease = prerelease == true || prerelease.to_s.match?(/\A(?:1|true|yes|on)\z/i)
          explicitly_prerelease || Gem::Version.new(number.to_s).prerelease?
        end
      end
    end
  end
end
