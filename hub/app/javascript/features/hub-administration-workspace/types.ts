import type { HubWorkspaceData } from "@features/hub-workspace/types"

export interface HubAdministrationWorkspaceData extends HubWorkspaceData {
  selectedSection: "audit" | "members" | "admins" | "sharing" | "sessions" | "github" | "copilot"
}
