export interface HomeIndexPageData {
  alert: string | null
  authenticityToken: string
  badge: string
  badgeAlternate: string
  description: string
  footerNote: string
  heading: string
  localMode: boolean
  notice: string | null
  pageTitle: string
  pauseAnimationLabel: string
  resumeAnimationLabel: string
  signInLabel: string
  signInPath: string | null
  emailLogin?: {
    email: string | null
    challengePath: string
    verifyPath: string
    restartPath: string
    emailLabel: string
    codeLabel: string
    sendLabel: string
    verifyLabel: string
    restartLabel: string
  }
}
