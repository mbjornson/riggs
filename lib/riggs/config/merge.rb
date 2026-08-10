# frozen_string_literal: true

module Riggs
  module Config
    # Three merge algebras, deliberately not one. A lost provider is a billing
    # surprise, a lost MCP server is a missing tool, and a lost skill is a
    # silent capability change, so replace-or-error, merge-by-key and
    # merge-with-gate cannot share an implementation.
    module Merge
      # An ALLOWLIST, not a denylist. A denylist has to enumerate every
      # dangerous key in advance and is wrong the moment one is added -- and it
      # was already wrong once: an earlier draft banned sqlite_path and said
      # nothing about sqlite_memory, whose vector_path and memory_path go
      # straight into enable_load_extension/load_extension in
      # MemoryService#load_extensions!. That is arbitrary native code loaded
      # without touching the MCP approval this phase exists to build.
      PROJECT_KEYS = %i[default_user roles users providers mcp_servers].freeze

      # Same reasoning one level down: banning api_key alone left token,
      # secret, password and a nested auth: hash wide open.
      #
      # `pricing` is deliberately NOT here. riggs exists to tell the operator
      # what their agents cost, and a project that sets its own pricing can
      # report $0.00 for a run that cost $60.00 -- measured, not theorised.
      # That defeats the product rather than merely bypassing a control, so
      # pricing is the operator's the same way credentials are. The matching
      # guard for workflow-declared pricing lives in Router#pricing_for.
      PROVIDER_FIELDS = %i[model base_url relay_chain auth].freeze

      # On a user the global tier already defines, only the role may change.
      # Everything else -- id, name, github_username, memory_namespace -- is
      # the operator's own record of who someone is.
      USER_OVERRIDE_FIELDS = %i[role].freeze

      Merged = Struct.new(:config, :provenance, keyword_init: true)
      Sections = Struct.new(:config, :provenance, keyword_init: true)

      def self.call(global:, project:, global_path:, project_path:)
        TierMerger.new(global: global, project: project, global_path: global_path, project_path: project_path).call
      end

      class TierMerger
        # global_path and project_path default to a readable placeholder rather
        # than nil: they appear verbatim in every diagnostic, and a nil one
        # renders "role 'engineer' is defined in  and cannot be redefined",
        # which fails the two-file requirement precisely when someone is
        # debugging a merge.
        #
        # This seam keeps diagnostics supplied by the required public interface
        # while avoiding optional parameters under the current Ruby standards.
        def initialize(global:, project:, global_path:, project_path:)
          @paths = { global: global_path, project: project_path }
          @global = mapping(global, :global)
          @project = mapping(project, :project)
        end

        def call
          return Merged.new(config: global, provenance: all_global) if project.empty?

          merge_project
        end

        private

        attr_reader :global, :project, :paths

        # ProjectShape checks each SECTION's shape; this checks the document
        # holding them. A top-level scalar reached .keys as a NoMethodError
        # rather than a configuration error, and `false` was silently
        # indistinguishable from "this repository has no project tier at all".
        # nil still means absent, which is how a missing file arrives.
        def mapping(tier, which)
          return {} if tier.nil?
          raise Error, "#{paths[which]}: the file must contain a mapping, got #{tier.class}" unless tier.is_a?(Hash)

          Identity.deep_symbolize(tier)
        end

        def merge_project
          ProjectKeys.new(project: project, paths: paths).validate!
          ProjectShape.new(project: project, paths: paths).validate!
          merge_sections
        end

        def merge_sections
          sections = SectionMerger.new(global: global, project: project, paths: paths).call
          ConfigValidator.new(config: sections.config, project_path: paths[:project]).validate!
          Merged.new(config: sections.config, provenance: sections.provenance)
        end

        def all_global
          all_global_sections.merge(default_user: :global)
        end

        def all_global_sections
          %i[roles users providers mcp_servers].to_h { |key| [key, tier_map(global[key], :global)] }
        end

        def tier_map(hash, tier)
          (hash || {}).keys.to_h { |key| [key, tier] }
        end
      end

      class ProjectKeys
        def initialize(project:, paths:)
          @project = project
          @paths = paths
        end

        def validate!
          return if unlisted.empty?

          raise Error, message
        end

        private

        attr_reader :project, :paths

        def unlisted
          project.keys - PROJECT_KEYS
        end

        def message
          "#{paths[:project]}: '#{unlisted.first}' may only be set in #{paths[:global]} " \
            "(a project may set: #{PROJECT_KEYS.map(&:to_s).sort.join(', ')})"
        end
      end

      # PROJECT_KEYS and PROVIDER_FIELDS compare NAMES. A value with no keys
      # has no names to compare, so `providers: {openai: "x"}` walked past
      # PROVIDER_FIELDS untouched and KeyMerger then substituted the string
      # for the whole global provider entry -- model, base_url, pricing,
      # relay_chain and auth all gone, with no error. Checking shape before
      # any algebra runs is what makes the name allowlists mean anything.
      #
      # The expected shape is per section, not one rule for all four: a role
      # maps to a LIST of permissions (Identity::DEFAULT_ROLES values are
      # Arrays), so a single "entries must be mappings" rule would reject
      # every legitimate roles: block in existence.
      class ProjectShape
        ENTRY_SHAPES = { roles: Array, users: Hash, providers: Hash, mcp_servers: Hash }.freeze

        def initialize(project:, paths:)
          @project = project
          @paths = paths
        end

        def validate!
          ENTRY_SHAPES.each_key { |section| validate_section!(section) }
        end

        private

        attr_reader :project, :paths

        # The section is checked before its entries are walked, so a section
        # that is not a mapping raises here rather than on #each.
        def validate_section!(section)
          return unless project.key?(section)

          reject!(section, nil, project[section], Hash)
          project[section].each { |name, value| reject!(section, name, value, ENTRY_SHAPES[section]) }
        end

        def reject!(section, name, value, shape)
          return if value.is_a?(shape)

          raise Error, message(section, name, value, shape)
        end

        def message(section, name, value, shape)
          "#{paths[:project]}: #{label(section, name)} must be a #{noun(shape)}, got #{value.class}"
        end

        def label(section, name)
          return section.to_s if name.nil?

          "#{section}.#{name}"
        end

        def noun(shape)
          return "list" if shape == Array

          "mapping"
        end
      end

      class SectionMerger
        ALGEBRAS = {
          roles: :RoleMerger,
          users: :UserMerger,
          providers: :ProviderMerger,
          mcp_servers: :KeyMerger
        }.freeze

        def initialize(global:, project:, paths:)
          @global = global
          @project = project
          @paths = paths
        end

        def call
          section_results = ALGEBRAS.to_h { |name, algebra| [name, merge(name, algebra)] }
          Sections.new(config: config(section_results), provenance: provenance(section_results))
        end

        private

        attr_reader :global, :project, :paths

        def merge(name, algebra)
          Merge.const_get(algebra).new(global: global[name], project: project[name], paths: paths).call
        end

        def config(results)
          global.merge(results.transform_values(&:first)).merge(default_user_config)
        end

        def provenance(results)
          results.transform_values(&:last).merge(default_user: default_user_provenance)
        end

        def default_user_config
          return {} unless project.key?(:default_user)

          { default_user: project[:default_user] }
        end

        def default_user_provenance
          return :global unless project.key?(:default_user)

          :project
        end
      end

      class RoleMerger
        # Assignment is local, definition is global. A project may name a role
        # the global tier has never heard of; it may not change what a global
        # word means, so that 'engineer' reads the same in every repo.
        def initialize(global:, project:, paths:)
          @global = global || {}
          @project = project || {}
          @paths = paths
        end

        def call
          reject_clash!
          [global.merge(project), global_tier_map.merge(project_tier_map)]
        end

        private

        attr_reader :global, :project, :paths

        def reject_clash!
          return if clash.empty?

          raise Error, "role '#{clash.first}' is defined in #{paths[:global]} and cannot be redefined by #{paths[:project]}"
        end

        def clash
          project.keys & global.keys
        end

        def global_tier_map
          tier_map(global, :global)
        end

        def project_tier_map
          tier_map(project, :project)
        end

        def tier_map(hash, tier)
          hash.keys.to_h { |key| [key, tier] }
        end
      end

      class UserMerger
        # A new user may describe itself fully; an existing one may only be
        # reassigned. Provenance is :project only for users the project
        # actually changed.
        def initialize(global:, project:, paths:)
          @global = global || {}
          @project = project || {}
          @paths = paths
        end

        def call
          merged = project.keys.reduce(global.dup) { |users, name| merge_user(users, name) }
          [merged, provenance(merged)]
        end

        private

        attr_reader :global, :project, :paths

        def merge_user(users, name)
          reject_extra_fields!(name)
          users.merge(name => user_for(name))
        end

        def reject_extra_fields!(name)
          return unless global.key?(name) && extra_fields(name).any?

          raise Error, invalid_fields_message(name)
        end

        def user_for(name)
          return fields_for(name) unless global.key?(name)

          global[name].merge(fields_for(name))
        end

        def fields_for(name)
          return project[name] if project[name].is_a?(Hash)

          {}
        end

        def extra_fields(name)
          fields_for(name).keys - USER_OVERRIDE_FIELDS
        end

        def invalid_fields_message(name)
          "#{paths[:project]}: user '#{name}' is defined globally, so only " \
            "#{USER_OVERRIDE_FIELDS.join(', ')} may be overridden (got '#{extra_fields(name).first}')"
        end

        # :project only when the value actually differs. Marking every
        # mentioned user :project would make R11.5 print "from
        # .riggs/config.yml" for a user the project merely restated.
        def provenance(merged)
          tier_map.merge(project.keys.to_h { |name| [name, tier_for(merged, name)] })
        end

        def tier_for(merged, name)
          return :global if merged[name] == global[name]

          :project
        end

        def tier_map
          global.keys.to_h { |key| [key, :global] }
        end
      end

      class ProviderMerger
        # A repo must not carry secrets, and it must not be able to introduce a
        # provider riggs would otherwise not dispatch. It may retune one, and
        # only through the listed fields.
        def initialize(global:, project:, paths:)
          @global = global || {}
          @project = project || {}
          @paths = paths
        end

        def call
          reject_unknown!
          project.each_key { |name| validate_fields!(name) }
          KeyMerger.new(global: global, project: project, paths: paths).call
        end

        private

        attr_reader :global, :project, :paths

        def reject_unknown!
          return if unknown.empty?

          raise Error, unknown_message
        end

        def unknown
          project.keys - global.keys
        end

        def unknown_message
          "#{paths[:project]} configures provider '#{unknown.first}' which is not defined " \
            "globally (defined: #{global.keys.map(&:to_s).sort.join(', ')})"
        end

        def validate_fields!(name)
          reject_extra_fields!(name)
          validate_auth!(name)
        end

        def reject_extra_fields!(name)
          return if extra_fields(name).empty?

          raise Error, extra_fields_message(name)
        end

        def extra_fields(name)
          fields_for(name).keys - PROVIDER_FIELDS
        end

        def fields_for(name)
          return project[name] if project[name].is_a?(Hash)

          {}
        end

        def extra_fields_message(name)
          "provider '#{name}': '#{extra_fields(name).first}' may not be set in #{paths[:project]} " \
            "(a project may set: #{PROVIDER_FIELDS.join(', ')}); credentials come from the environment"
        end

        # `auth` names a mode -- "subscription", "api", "none". Anything
        # that is not a String or Symbol is rejected: a Hash would smuggle
        # api_key back in under an allowlisted key (the check above only
        # looks one level down), and false/nil/1 are not mode names either,
        # so an allowlist of TYPES beats a denylist of them.
        def validate_auth!(name)
          return unless fields_for(name).key?(:auth) && !auth_is_a_mode?(name)

          raise Error, "provider '#{name}': 'auth' must be a mode name, got #{fields_for(name)[:auth].inspect}, " \
                       "in #{paths[:project]}"
        end

        def auth_is_a_mode?(name)
          fields_for(name)[:auth].is_a?(String) || fields_for(name)[:auth].is_a?(Symbol)
        end
      end

      class KeyMerger
        def initialize(global:, project:, paths:)
          @global = global || {}
          @project = project || {}
          @paths = paths
        end

        def call
          [merge_values, global_tier_map.merge(project_tier_map)]
        end

        private

        attr_reader :global, :project, :paths

        def merge_values
          global.merge(project, &method(:merge_value))
        end

        def merge_value(_key, global_value, project_value)
          return project_value unless global_value.is_a?(Hash) && project_value.is_a?(Hash)

          global_value.merge(project_value)
        end

        def global_tier_map
          tier_map(global, :global)
        end

        def project_tier_map
          tier_map(project, :project)
        end

        def tier_map(hash, tier)
          hash.keys.to_h { |key| [key, tier] }
        end
      end

      class ConfigValidator
        def initialize(config:, project_path:)
          @config = config
          @project_path = project_path
        end

        def validate!
          validate_user_roles!
          validate_default_user!
        end

        private

        attr_reader :config, :project_path

        def validate_user_roles!
          users.each { |name, cfg| validate_role!(name, cfg) }
        end

        def validate_role!(name, cfg)
          return if role_for(cfg).empty? || known_roles.include?(role_for(cfg))

          raise Error, "#{project_path}: user '#{name}' names role '#{role_for(cfg)}' which is not defined " \
                       "(defined: #{known_roles.sort.join(', ')})"
        end

        def role_for(cfg)
          return "" unless cfg.is_a?(Hash)

          cfg[:role].to_s
        end

        def known_roles
          (config[:roles] || {}).keys.map(&:to_s) | Identity::DEFAULT_ROLES.keys.map(&:to_s)
        end

        def validate_default_user!
          return if default_user.empty? || users.key?(default_user.to_sym)

          raise Error, "#{project_path}: default_user '#{default_user}' is not defined in either tier"
        end

        def default_user
          config[:default_user].to_s
        end

        def users
          config[:users] || {}
        end
      end
    end
  end
end
