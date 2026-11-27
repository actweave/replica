import { z } from "zod"

const person = z.object({
  login: z.string().min(1).max(39),
  avatarUrl: z.string().nullable(),
})

export const MENTION_CANDIDATES_SCHEMA = z
  .object({
    candidates: z.array(
      person.extend({ githubId: z.number().int().positive().max(Number.MAX_SAFE_INTEGER) }),
    ),
    externalCandidates: z.array(person.extend({ name: z.string().nullable() })).optional(),
  })
  .transform(({ candidates, externalCandidates }) => ({
    candidates: [...(externalCandidates ?? []), ...candidates],
  }))
