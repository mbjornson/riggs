# frozen_string_literal: true

module Riggs
  module Triggers
    # text nil/blank → workflows that are manually runnable (manual trigger or no triggers).
    # text present → keyword triggers whose keywords appear in the text (manual alone does not match).
    # rubocop:disable Naming/PredicateMethod
    def self.match(workflow, text:)
      triggers = Array(workflow[:triggers])
      return true if triggers.empty?
      return manual?(triggers) if text.nil? || text.to_s.strip.empty?

      keyword_match?(triggers, text)
    end
    # rubocop:enable Naming/PredicateMethod

    # Ordered roots, first match by workflow NAME wins. Shadowing rather than
    # merging: a project triage.yml replaces the global one instead of both
    # appearing. A global workflow with a keyword trigger fires in every repo,
    # which is the point of the tier -- so every entry reports which tier it
    # came from, or an operator cannot explain a match against a file that is
    # not in the repo.
    def self.default_roots
      WorkflowRoots.new.default_roots
    end

    # Tier is derived from the root's own path, not its index: default_roots
    # compacts away an untrusted project root, so index 0 is not always the
    # project and a positional rule would relabel the global tier as project
    # for exactly the repos where that claim is most misleading.
    #
    # Exact comparison of expanded paths, not start_with?. A prefix test calls
    # /tmp/riggs-home-evil "global" when RIGGS_HOME=/tmp/riggs-home, and calls
    # a project living under RIGGS_HOME global too.
    def self.tier_for(dir)
      WorkflowRoots.new.tier_for(dir)
    end

    # The one place a workflow NAME becomes a file path. Before this,
    # CLI#load_workflow and WebApp#workflow_path each hardcoded
    # config/riggs/workflows, and web/app.rb reached them from show, run and
    # resume -- so gating default_roots governed what `triggers:list` displayed
    # and nothing that executed. First root wins, matching skill resolution.
    def self.find_path(name, roots: nil)
      WorkflowRoots.new.find_path(name, roots: roots)
    end

    # Where a writer puts a new workflow. Separate from find_path because
    # creating a file is not looking one up: there is exactly one correct
    # destination, and it is the project's own root whether or not anything
    # is there yet.
    def self.project_workflows_dir
      WorkflowRoots.new.project_workflows_dir
    end

    def self.safe_name(name)
      WorkflowRoots.new.safe_name(name)
    end

    # Carries the tier out with each match. The spec requires BOTH triggers:list
    # and triggers:match to report it, and discarding it here left
    # triggers_match unable to explain why a workflow that is not in the repo
    # matched -- which is the case the tier exists to explain.
    #
    # The optional dir: alias deliberately preserves existing one-root callers.
    def self.find_workflows(text:, dir: nil, roots: nil)
      matching = []
      each_declared(roots_for(roots, dir)) do |workflow, _path, tier|
        matching << workflow.merge(tier: tier) if match(workflow, text: text)
      end
      matching
    end

    def self.list_declared(dir: nil, roots: nil)
      declared = WorkflowDeclarations.new(roots_for(roots, dir)).to_a
      # The existing method sorts by name before returning (triggers.rb:45).
      # Dropping it makes output root-order-dependent and breaks callers that
      # rely on a stable list.
      declared.sort_by { |workflow| workflow[:name].to_s }
    end

    def self.summarize_trigger(trigger)
      TriggerSummary.new(trigger).to_h
    end

    def self.each_declared(roots, &)
      WorkflowDeclarations.new(roots).each(&)
    end

    def self.manual?(triggers)
      triggers.any? { |trigger| trigger[:type].to_s == "manual" }
    end

    def self.keyword_match?(triggers, text)
      triggers.any? { |trigger| keyword_matches?(trigger, text) }
    end

    def self.keyword_matches?(trigger, text)
      return false unless trigger[:type].to_s == "keyword"

      Array(trigger[:keywords]).map(&:to_s).any? { |word| word_present?(word, text) }
    end

    def self.word_present?(word, text)
      !word.empty? && text.to_s.downcase.include?(word.downcase)
    end

    def self.roots_for(roots, dir)
      return roots if roots
      return [dir] if dir

      default_roots
    end

    private_class_method :manual?, :keyword_match?, :keyword_matches?, :word_present?, :roots_for
  end

  class WorkflowRoots
    def default_roots
      [project_root, global_root, bundled_root].compact
    end

    def tier_for(dir)
      return :global if expanded(dir) == expanded(global_root)
      return :bundled if expanded(dir) == expanded(bundled_root)

      :project
    end

    def find_path(name, roots: nil)
      # A name is a NAME, not a path. File.join(dir, "../../etc/x.yml") escapes
      # every trusted root, and `name` arrives from `riggs workflow:run NAME`
      # and from the /api/workflows/:name/run route -- so this is remote path
      # traversal, not just a local footgun.
      safe = safe_name(name)
      return nil unless safe

      candidate_in(roots || default_roots, safe)
    end

    def project_workflows_dir
      File.join(Config::Resolver.project_path, "config", "riggs", "workflows")
    end

    def safe_name(name)
      base = File.basename(name.to_s)
      return nil if base.empty? || base != name.to_s || base.start_with?(".")

      base
    end

    private

    # The project root is nil unless the path is trusted, so an untrusted repo
    # contributes no workflows and resolution falls through to global and bundled.
    def project_root
      Config::Resolver.new.project_roots[:workflows]
    end

    def global_root
      File.join(Trust.home, "workflows")
    end

    def bundled_root
      File.expand_path("../../config/riggs/workflows", __dir__)
    end

    def expanded(path)
      File.expand_path(path.to_s)
    end

    def candidate_in(roots, safe)
      Array(roots).compact.map { |dir| contained_candidate(dir, safe) }.compact.first
    end

    def contained_candidate(dir, safe)
      candidate = File.join(dir, "#{safe}.yml")
      return nil unless File.exist?(candidate)
      #
      # The syntactic guard stops `../`; it does not stop a SYMLINK inside
      # the root pointing out of it. Containment is checked on real paths.
      return nil unless contained?(candidate, dir)

      candidate
    end

    def contained?(candidate, dir)
      real_dir = File.realpath(dir)
      File.realpath(candidate).start_with?("#{real_dir}#{File::SEPARATOR}")
    rescue SystemCallError
      false
    end
  end

  class WorkflowDeclarations
    def initialize(roots)
      @roots = roots
    end

    def each
      seen = {}
      Array(@roots).compact.each { |dir| read(dir, seen) { |workflow, path| yield(workflow, path, Triggers.tier_for(dir)) } }
    end

    def to_a
      entries = []
      each { |workflow, path, tier| entries << entry(workflow, path, tier) }
      entries
    end

    private

    def read(dir, seen)
      Dir.glob(File.join(dir, "*.yml")).each { |path| yield_loaded(path, seen) { |workflow| yield(workflow, path) } }
    end

    def yield_loaded(path, seen)
      workflow = Workflow::Loader.load(path: path)
      name = workflow[:name].to_s
      return if seen.key?(name)

      seen[name] = true
      yield(workflow)
    rescue WorkflowError
      nil
    end

    def entry(workflow, path, tier)
      { name: workflow[:name], display_name: workflow[:display_name], path: path, tier: tier,
        triggers: Array(workflow[:triggers]).map { |trigger| Triggers.summarize_trigger(trigger) } }
    end
  end

  class TriggerSummary
    def initialize(trigger)
      @trigger = trigger
    end

    def to_h
      summary = { type: type }
      summary[:keywords] = keywords if keyword?
      summary
    end

    private

    def type
      @trigger[:type].to_s
    end

    def keyword?
      type == "keyword"
    end

    def keywords
      Array(@trigger[:keywords]).map(&:to_s)
    end
  end
end
