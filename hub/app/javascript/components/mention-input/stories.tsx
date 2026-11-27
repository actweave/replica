import { useMemo, useState } from "react"
import type { Meta, StoryObj } from "@storybook/react-vite"

import { MentionProvider } from "@components/mention-provider"
import { mona, octocat } from "@/storybook/fixtures/users"

import { MentionInput } from "."

const meta = {
  title: "Components/Mention input",
  component: MentionInput,
  args: { "aria-label": "Comment", value: "Please review @", onValueChange: () => {} },
  render: function MentionStory(args) {
    const [value, setValue] = useState(args.value)
    const source = useMemo(
      () => ({
        load: () =>
          Promise.resolve([
            { login: "reviewer-123", name: "Jordan", avatarUrl: null },
            { login: mona.login, avatarUrl: mona.avatarUrl, githubId: 1002 },
            { login: octocat.login, avatarUrl: octocat.avatarUrl, githubId: 1001 },
          ]),
        copy: {
          suggestions: "Mention suggestions",
          error: "Unavailable",
          loading: "Loading people...",
          empty: "No matches",
          retry: "Retry",
        },
      }),
      [],
    )
    return (
      <MentionProvider source={source}>
        <MentionInput {...args} value={value} onValueChange={setValue} />
      </MentionProvider>
    )
  },
} satisfies Meta<typeof MentionInput>

export default meta
type Story = StoryObj<typeof meta>
export const People: Story = {}
export const PlainText: Story = { args: { value: "Please review the spacing." } }
