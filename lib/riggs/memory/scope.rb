# frozen_string_literal: true

module Riggs
  # R11.7. Memory never crosses projects, achieved by composing the namespace
  # rather than by adding a column.
  #
  # MemoryService filters `WHERE m.namespace = ?`, and its sqlite-vector backend
  # independently scopes by paths ending `_by_<namespace>`. Composition scopes
  # BOTH with one change. A project_path column would scope the SQL backend and
  # silently miss the vector one -- the failure mode where recall appears to
  # work in tests and leaks in the field.
  #
  # Composed where the namespace is born, in Identity, so none of the four
  # places that construct a MemoryService can forget to do it.
  class MemoryScope
    SEPARATOR = "@"

    def self.compose(namespace:, project_path:)
      "#{namespace}#{SEPARATOR}#{project_path}"
    end
  end
end
