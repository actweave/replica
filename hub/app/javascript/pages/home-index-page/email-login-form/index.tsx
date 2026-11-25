import { Button, TextInput } from "@primer/react-brand/esm"

import type { HomeIndexPageData } from "../types"

export function EmailLoginForm({
  login,
  token,
}: {
  login: NonNullable<HomeIndexPageData["emailLogin"]>
  token: string
}) {
  const verifying = login.email !== null
  return (
    <form
      className="home__email-login"
      action={verifying ? login.verifyPath : login.challengePath}
      method="post"
    >
      <input type="hidden" name="authenticity_token" value={token} />
      {verifying ? (
        <>
          <input type="hidden" name="email" value={login.email ?? ""} />
          <label htmlFor="email-login-code">{login.codeLabel}</label>
          <TextInput
            id="email-login-code"
            name="code"
            autoComplete="one-time-code"
            inputMode="numeric"
            pattern="[0-9]{6}"
            maxLength={6}
            fullWidth
            required
          />
        </>
      ) : (
        <>
          <label htmlFor="email-login-address">{login.emailLabel}</label>
          <TextInput
            id="email-login-address"
            name="email"
            type="email"
            autoComplete="email"
            maxLength={254}
            fullWidth
            required
          />
        </>
      )}
      <Button type="submit" variant="primary">
        {verifying ? login.verifyLabel : login.sendLabel}
      </Button>
      {verifying && <a href={login.restartPath}>{login.restartLabel}</a>}
    </form>
  )
}
