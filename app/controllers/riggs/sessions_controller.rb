# frozen_string_literal: true

module Riggs
  class SessionsController < ApplicationController
    def show
      require_riggs_permission!(:inspect_run, :read_workflow)
      session = storage.find_session(params[:id])
      return render(json: { error: "not found" }, status: :not_found) unless session

      render json: session
    end

    def audit
      require_riggs_permission!(:inspect_run)
      rows = storage.list_audit(params[:id])
      render json: rows
    end

    def approve
      require_riggs_permission!(:approve_gates)
      storage.audit(session_id: params[:id], event_type: "gate_decision", payload: { decision: "approved", via: "web" })
      storage.update_session(params[:id], status: "running")
      render json: { ok: true, decision: "approved" }
    end

    def reject
      require_riggs_permission!(:approve_gates)
      storage.audit(session_id: params[:id], event_type: "gate_decision", payload: { decision: "rejected", via: "web" })
      storage.update_session(params[:id], status: "rejected", ended: true)
      render json: { ok: true, decision: "rejected" }
    end
  end
end
