import { ThemeProvider } from "@primer/react-brand/esm"
import { fireEvent, render, screen, within } from "@testing-library/react"
import { expect, it } from "vitest"
import { AccessManagementPage } from "."
import meta, { Members } from "./stories"

it("submits the chosen role and confirms removal for the selected membership", () => {
  const data = Members.args!.data!
  render(
    <ThemeProvider>
      <AccessManagementPage data={data} />
    </ThemeProvider>,
  )
  const row = screen.getByText("writer@example.com").closest("li")!
  const role = within(row).getByRole("combobox")
  fireEvent.change(role, { target: { value: "admin" } })
  const form = role.closest("form")!
  expect(new FormData(form).get("role")).toBe("admin")
  expect(new FormData(form).get("_method")).toBe("patch")
  fireEvent.click(within(row).getByRole("button", { name: "Remove" }))
  const removal = within(row).getByRole("button", { name: "Confirm removal" }).closest("form")!
  expect(removal.action).toBe(form.action)
  expect(new FormData(removal).get("_method")).toBe("delete")
  fireEvent.click(within(row).getByRole("button", { name: "Cancel" }))
  expect(screen.queryByRole("button", { name: "Confirm removal" })).toBeNull()
})

it("sends an optional Hub administrator designation with the allowlisted email", () => {
  render(
    <ThemeProvider>
      <AccessManagementPage data={meta.args.data} />
    </ThemeProvider>,
  )
  fireEvent.change(screen.getByLabelText("Email address"), {
    target: { value: "admin@example.com" },
  })
  fireEvent.click(screen.getByRole("checkbox", { name: "Hub administrator" }))
  const form = screen.getByRole("button", { name: "Add email" }).closest("form")!
  expect(new FormData(form).get("email")).toBe("admin@example.com")
  expect(new FormData(form).get("hub_admin")).toBe("1")
})
