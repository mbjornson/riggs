# frozen_string_literal: true

module Riggs
  # Who may execute a given workflow. Four entry points execute one --
  # `workflow:run`, `workflow:resume`, POST /workflows/:name/run and the JSON
  # API -- and each gated on the flat `run_workflow` permission. A rule
  # re-expressed at four call sites is a rule three of them will eventually
  # disagree about, so it is expressed once, here, and they all ask.
  #
  # Two permissions, not a list of names in the config: `run_workflow` runs
  # anything, and `run_owned_workflow` runs only what the role owns. The
  # workflow carries a LABEL (`owner_role`); the operator's tier carries the
  # GRANT. A label nobody granted opens nothing.
  class WorkflowAccess
    ANY = "run_workflow"
    OWNED = "run_owned_workflow"

    def self.denial(identity:, workflow:, tier:)
      new(identity: identity, workflow: workflow, tier: tier).denial
    end

    def initialize(identity:, workflow:, tier:)
      @identity = identity
      @workflow = workflow
      @tier = tier
    end

    # nil when permitted, otherwise the sentence to show the operator. One
    # return value so the CLI can abort with it and the web app can raise with
    # it without either restating the rule.
    def denial
      return nil if permitted?

      message
    end

    private

    def permitted?
      return true if permission?(ANY)

      permission?(OWNED) && owned? && operator_supplied?
    end

    def permission?(name)
      Array(@identity[:permissions]).map(&:to_s).include?(name)
    end

    def owned?
      !owner.empty? && owner == role
    end

    def owner
      @workflow[:owner_role].to_s
    end

    def role
      @identity[:role].to_s
    end

    def name
      @workflow[:name].to_s
    end

    # Trust is granted once, and a repository stays mutable afterwards, so a
    # project-tier workflow may not label itself into a role the operator
    # never opted that repository into -- the same reason a project may not
    # set its own base_url. Global and bundled workflows are the operator's
    # own, and carry the label as written.
    def operator_supplied?
      @tier != :project
    end

    def message
      return no_permission_message unless permission?(OWNED)
      return project_message if owned?
      return unowned_message if owner.empty?

      other_owner_message
    end

    def no_permission_message
      "'#{role}' lacks required permission(s): #{ANY} or #{OWNED}"
    end

    def project_message
      "'#{name}' is declared by this repository, so running it needs #{ANY} " \
        "(a repository may not assign itself an owner_role)"
    end

    def unowned_message
      "'#{name}' declares no owner_role, so running it needs #{ANY}; " \
        "'#{role}' may only run workflows it owns"
    end

    def other_owner_message
      "'#{name}' is owned by '#{owner}', and '#{role}' may only run workflows it owns"
    end
  end
end
