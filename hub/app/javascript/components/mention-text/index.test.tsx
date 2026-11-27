import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"

import { octocatRootComment } from "@/storybook/fixtures/review/comments"

import { MentionText } from "."

describe("MentionText()", () => {
  it("renders an external name for the stored handle", () => {
    render(
      <MentionText
        comment={{
          ...octocatRootComment,
          body: "Hello @reviewer-123",
          externalMentions: [{ login: "reviewer-123", name: "Jordan" }],
        }}
      />,
    )
    expect(screen.getByText("@Jordan")).toBeVisible()
  })

  it("highlights only server-recognized tokens and never renders markup", () => {
    const { container } = render(
      <p>
        <MentionText
          comment={{
            ...octocatRootComment,
            body: "@mona @hubot email@mona <script>unsafe</script>",
            mentions: [{ login: "mona", githubId: 1002 }],
          }}
        />
      </p>,
    )
    expect(container.querySelectorAll(".mention-text")).toHaveLength(1)
    expect(container.querySelector(".mention-text")).toHaveTextContent("@mona")
    expect(container.querySelector("script")).toBeNull()
    expect(screen.getByText(/<script>unsafe<\/script>/)).toBeInTheDocument()
  })
})
