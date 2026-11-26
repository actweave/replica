import { useState } from "react"
import { Button, Heading, Text } from "@primer/react-brand/esm"
import { HubAdministrationPage } from "@features/hub-administration-page"
import type { AccessManagementData, Role } from "./types"
import "./styles.css"

function RoleSelect({ data, role = "read" }: { data: AccessManagementData; role?: Role }) {
  return (
    <label>
      {data.copy.role}
      <select defaultValue={role} name="role">
        <option value="read">{data.copy.read}</option>
        <option value="write">{data.copy.write}</option>
        <option value="admin">{data.copy.adminRole}</option>
      </select>
    </label>
  )
}

export function AccessManagementPage({ data }: { data: AccessManagementData }) {
  const [removing, setRemoving] = useState<number | null>(null)
  const { copy } = data
  const token = <input type="hidden" name="authenticity_token" value={data.authenticityToken} />
  return (
    <HubAdministrationPage data={data}>
      <div className="access-management">
        <Text as="p">{copy.verification}</Text>
        <form method="post" action={data.submitPath}>
          {token}
          {data.kind === "members" ? (
            <>
              <label>
                {copy.recipient}
                <input name="recipient" required />
              </label>
              <RoleSelect data={data} />
            </>
          ) : (
            <>
              <label>
                {copy.email}
                <input type="email" name="email" maxLength={254} required />
              </label>
              <label>
                <input type="checkbox" name="hub_admin" value="1" /> {copy.admin}
              </label>
            </>
          )}
          <Button type="submit" variant="primary">
            {data.kind === "members" ? copy.grant : copy.add}
          </Button>
        </form>
        {data.rows.length ? (
          <ul>
            {data.rows.map((row) => (
              <li key={row.id}>
                <strong>{row.label}</strong>
                {"hubAdmin" in row && row.hubAdmin && <Text>{copy.admin}</Text>}
                {"role" in row && (
                  <>
                    {row.pending && <Text>{copy.pending}</Text>}
                    <form method="post" action={row.path} aria-label={row.label}>
                      {token}
                      <input type="hidden" name="_method" value="patch" />
                      <RoleSelect data={data} role={row.role} />
                      <Button type="submit">{copy.save}</Button>
                    </form>
                  </>
                )}
                {removing === row.id ? (
                  <form method="post" action={row.path} aria-label={row.label}>
                    {token}
                    <input type="hidden" name="_method" value="delete" />
                    <Text>{data.kind === "members" ? copy.removeGrant : copy.removeEmail}</Text>
                    <Button type="submit">{copy.confirm}</Button>
                    <Button type="button" onClick={() => setRemoving(null)}>
                      {copy.cancel}
                    </Button>
                  </form>
                ) : (
                  <Button type="button" onClick={() => setRemoving(row.id)}>
                    {copy.remove}
                  </Button>
                )}
              </li>
            ))}
          </ul>
        ) : (
          <Text as="p">{copy.empty}</Text>
        )}
        {data.kind === "allowlist" && data.repositories.length > 0 && (
          <section>
            <Heading as="h2" size="6">
              {copy.repositories}
            </Heading>
            <ul>
              {data.repositories.map((repo) => (
                <li key={repo.path}>
                  <a href={repo.path}>{repo.label}</a>
                </li>
              ))}
            </ul>
          </section>
        )}
      </div>
    </HubAdministrationPage>
  )
}
