# frozen_string_literal: true

require "psych"
require "fileutils"
require "time"
require_relative "config/merge"
require_relative "config/resolver"

module Riggs
  # Safe read/merge/write for ONE configuration tier (never silent clobber).
  # Which tier it is decides what may be written into it, so the store carries
  # the tier rather than leaving each caller to work it out again.
  class ConfigStore
    # View labels, not configuration. public_view is what GET /api/config
    # returns and what the raw-YAML textarea renders, so anything it carries
    # arrives back on the next write; stripping at the write boundary covers
    # both round trips in one place instead of two.
    METADATA_PREFIX = "_"

    # Both facts come from ONE resolution. Asking Identity for the path and
    # then deciding the tier separately is two computations of the same thing,
    # and they disagree the moment trust changes between the two calls.
    def self.default(cwd:, trust:)
      resolved = Identity.resolved(cwd: cwd, trust: trust)
      return new(path: resolved.project_config_path, tier: :project, trust: trust) if resolved.project_config_path

      new(path: Config::Resolver.global_config, tier: :global, trust: trust)
    end

    def initialize(path:, tier:, trust:)
      @path = path
      @tier = TierGuard.new(path: path, tier: tier, trust: trust).verified
    end

    attr_reader :path, :tier

    def read
      raise Error, "Missing config at #{@path}. Run 'riggs setup' first." unless File.exist?(@path)

      Identity.load_file!(@path)
    end

    # Secrets masked, and labelled with the tier and file it came from: with
    # two tiers, an unlabelled view leaves the operator editing one file while
    # reading another.
    def public_view
      public_document.merge("_tier" => @tier.to_s, "_path" => @path)
    end

    # The same view without the labels, for the raw-YAML editor: rendering
    # keys into a textarea that the write boundary then strips shows the
    # operator a document that is not the one they are editing.
    def public_document
      Document.mask(Document.stringify(read))
    end

    def merge!(patch)
      raise Error, "Missing config at #{@path}" unless File.exist?(@path)

      write!(Document.deep_merge(Document.stringify(read), Document.stringify(patch)))
      read
    end

    # Validation precedes backup! deliberately. This is reachable from POST
    # /config, and writing first left the repository holding a file no later
    # command could merge -- every riggs run in that repo raised until someone
    # hand-edited it, an outage a remote form could cause.
    def write!(config_hash)
      raise Error, "Missing config at #{@path}" unless File.exist?(@path)

      document = Document.without_metadata(Document.stringify(config_hash))
      Validator.new(path: @path, tier: @tier).validate!(document)
      persist(document)
    end

    def backup!
      return unless File.exist?(@path)

      FileUtils.cp(@path, "#{@path}.bak.#{Time.now.utc.strftime('%Y%m%d%H%M%S')}")
    end

    private

    def persist(document)
      backup!
      File.write(@path, Psych.dump(document))
      @path
    end

    # Whether a path may be opened at all, and whether the tier it claims is
    # the tier it is. Identity.config_path returns nil for an untrusted
    # project, but a caller can still name the file explicitly -- web/app.rb
    # hands ConfigStore a path -- so the refusal has to live here too, or the
    # gate has a second door standing open beside it.
    class TierGuard
      TIERS = %i[project global].freeze

      def initialize(path:, tier:, trust:)
        @path = path
        @tier = tier
        @trust = trust
      end

      def verified
        reject_unknown_tier!
        reject_mislabelled!
        reject_untrusted!
        @tier
      end

      private

      def reject_unknown_tier!
        return if TIERS.include?(@tier)

        raise Error, "Unknown config tier #{@tier.inspect} (expected :project or :global)"
      end

      # A stated tier is checked, not believed: labelling a project path
      # :global is how a caller would otherwise route repository-supplied
      # content around every project-tier guard below it.
      def reject_mislabelled!
        return if actual == @tier

        raise Error, "#{@path} is the #{actual} tier, not the #{@tier} tier"
      end

      # Compared as FILES, not as strings. `.`, `..` and symlink spellings all
      # name the global config while comparing unequal to it, and the raw
      # string comparison labelled every one of them :project -- which write!
      # then honoured, truncating the operator's own config, credentials and
      # all, under project rules. It failed the other way too: a respelled
      # global path stated as :global was refused as a project file.
      def actual
        return :global if canonical(@path) == canonical(Config::Resolver.global_config)

        :project
      end

      # realpath resolves symlinks but requires the file to exist, and a config
      # that has not been created yet is ordinary here -- so a missing file
      # falls back to resolving the directory it would live in.
      def canonical(path)
        return File.realpath(path) if File.exist?(path)

        File.join(canonical_dir(File.dirname(path)), File.basename(path))
      end

      def canonical_dir(dir)
        return File.realpath(dir) if File.exist?(dir)

        File.expand_path(dir)
      end

      def reject_untrusted!
        return if @tier == :global || @trust.trusted?(project_path)

        raise Error, "#{@path} belongs to #{project_path}, which is not trusted. Run 'riggs trust' there first."
      end

      # Resolved the way every other consumer resolves it, so a grant made by
      # `riggs trust` is the same string this compares against.
      def project_path
        Config::Resolver.project_path(File.dirname(@path))
      end
    end

    # Runs the real merge algebra against the candidate before anything
    # touches the file. Validating in Config::Merge alone is not enough:
    # write! backed up and wrote, and only a LATER command merged, so an
    # unmergeable document was already on disk by the time anyone found out.
    class Validator
      def initialize(path:, tier:)
        @path = path
        @tier = tier
      end

      def validate!(document)
        Config::Merge.call(
          global: global_slot(document), project: project_slot(document),
          global_path: Config::Resolver.global_config, project_path: @path
        )
      end

      private

      # The candidate is checked in the slot it will occupy. A global
      # candidate merges against an empty project because the operator owns
      # that tier -- the same asymmetry the merge algebra already encodes.
      def global_slot(document)
        return document if @tier == :global

        Config::ConfigFile.load(Config::Resolver.global_config)
      end

      def project_slot(document)
        return {} if @tier == :global

        document
      end
    end

    # Hash algebra, with no knowledge of tiers or files. normalize_patch and
    # deep_stringify were two implementations of one operation; they are one.
    class Document
      SECRET_KEY_HINTS = /(api_key|token|password|secret|credential)/i
      MASK = "••••••••"

      def self.stringify(obj)
        return obj.each_with_object({}) { |(key, value), out| out[key.to_s] = stringify(value) } if obj.is_a?(Hash)
        return obj.map { |value| stringify(value) } if obj.is_a?(Array)

        obj
      end

      def self.without_metadata(hash)
        hash.reject { |key, _| key.to_s.start_with?(METADATA_PREFIX) }
      end

      def self.deep_merge(base, overlay)
        return overlay unless base.is_a?(Hash) && overlay.is_a?(Hash)

        base.merge(overlay) { |_key, old_value, new_value| deep_merge(old_value, new_value) }
      end

      def self.mask(obj)
        return obj.each_with_object({}) { |(key, value), out| out[key.to_s] = masked(key.to_s, value) } if obj.is_a?(Hash)
        return obj.map { |value| mask(value) } if obj.is_a?(Array)

        obj
      end

      def self.masked(key, value)
        return MASK if secret?(key) && !value.nil? && !value.to_s.empty?

        mask(value)
      end

      def self.secret?(key)
        key.match?(SECRET_KEY_HINTS)
      end
    end
  end
end
