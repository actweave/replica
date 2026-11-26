import type { Meta, StoryObj } from "@storybook/react-vite"
import { hubAdministrationData } from "@/storybook/fixtures/hub-administration"
import { AccessManagementPage } from "."
import type { AccessManagementData } from "./types"

const copy = {
  email: "Email address",
  recipient: "Allowlisted email or Hub user ID",
  admin: "Hub administrator",
  role: "Repository role",
  read: "Read",
  write: "Write",
  adminRole: "Admin",
  add: "Add email",
  grant: "Grant access",
  save: "Save role",
  remove: "Remove",
  cancel: "Cancel",
  confirm: "Confirm removal",
  pending: "Awaiting first sign-in",
  empty: "No entries yet.",
  repositories: "Manage repository members",
  verification: "Changes require sign-in on this browser within the last five minutes.",
  removeEmail: "Removing this email ends its external sessions and removes its repository grants.",
  removeGrant: "Remove this explicit repository grant?",
}
const allowlist: AccessManagementData = {
  ...hubAdministrationData,
  kind: "allowlist",
  copy,
  heading: "Email allowlist",
  description: "Manage who can sign in by email and who can administer this Hub.",
  submitPath: "/auth_allowlist_entries",
  rows: [{ id: 1, label: "owner@example.com", hubAdmin: true, path: "/auth_allowlist_entries/1" }],
  repositories: [{ label: "example/design", path: "/repositories/2001/memberships" }],
}

const meta = {
  title: "Hub/Pages/Security/Access management",
  component: AccessManagementPage,
  parameters: { layout: "fullscreen" },
  args: { data: allowlist },
  decorators: [
    (Story) => (
      <div onSubmit={(event) => event.preventDefault()}>
        <Story />
      </div>
    ),
  ],
} satisfies Meta<typeof AccessManagementPage>
export default meta
type Story = StoryObj<typeof meta>
export const Allowlist: Story = {}
const members: AccessManagementData = {
  ...hubAdministrationData,
  administrationWorkspace: null,
  authenticatedWorkspace: {
    ...hubAdministrationData.administrationWorkspace,
    administrationLinks: [],
    selectedSection: "members",
    membersLabel: "Repository members",
    membersPath: "/repositories/2001/memberships",
  },
  kind: "members",
  copy,
  heading: "Repository members",
  description:
    "Manage explicit access to github/prototype. GitHub permissions can also grant access.",
  submitPath: "/repositories/2001/memberships",
  rows: [
    {
      id: 1,
      label: "reader@example.com",
      role: "read",
      pending: false,
      path: "/repositories/2001/memberships/1",
    },
    {
      id: 2,
      label: "writer@example.com",
      role: "write",
      pending: true,
      path: "/repositories/2001/memberships/2",
    },
  ],
}

export const Members: Story = { args: { data: members } }
export const NoMembers: Story = { args: { data: { ...members, rows: [] } } }
export const ConfirmRemoval: Story = {
  play: async ({ canvas, userEvent }) => {
    await userEvent.click(canvas.getByRole("button", { name: "Remove" }))
    await canvas.findByRole("button", { name: "Confirm removal" })
  },
}
