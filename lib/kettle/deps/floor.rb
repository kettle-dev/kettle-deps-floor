# frozen_string_literal: true

require "version_gem"
require_relative "floor/version"

module Kettle
  module Deps
    module Floor
      class Error < StandardError; end
      # Your code goes here...
    end
  end
end

Kettle::Deps::Floor::Version.class_eval do
  extend VersionGem::Basic
end
