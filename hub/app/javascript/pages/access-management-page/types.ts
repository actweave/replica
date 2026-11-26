import type { HubAdministrationPageData } from "@features/hub-administration-page/types"

type Copy = Record<
  | "email"
  | "recipient"
  | "admin"
  | "role"
  | "read"
  | "write"
  | "adminRole"
  | "add"
  | "grant"
  | "save"
  | "remove"
  | "cancel"
  | "confirm"
  | "pending"
  | "empty"
  | "repositories"
  | "verification"
  | "removeEmail"
  | "removeGrant",
  string
>

type Row = { id: number; label: string; path: string }
export type Role = "read" | "write" | "admin"
export type AccessManagementData = HubAdministrationPageData & {
  copy: Copy
  submitPath: string
} & (
    | {
        kind: "allowlist"
        rows: (Row & { hubAdmin: boolean })[]
        repositories: { label: string; path: string }[]
      }
    | { kind: "members"; rows: (Row & { role: Role; pending: boolean })[] }
  )
