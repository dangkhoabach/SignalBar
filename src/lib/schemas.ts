import { z } from "zod";

export const targetFormSchema = z
  .object({
    name: z.string().optional(),
    url: z.string().url("URL không hợp lệ (vd: https://example.com)"),
    group_tag: z.string().optional(),
    check_interval_secs: z.coerce.number().int().min(30, "Tối thiểu 30 giây"),
    check_http: z.boolean(),
    expected_status: z.coerce.number().int().min(100).max(599),
    check_ssl: z.boolean(),
    check_domain: z.boolean(),
    custom_path: z.string().optional(),
    expected_body_contains: z.string().optional(),
  })
  .transform((data) => ({
    ...data,
    // Leaving Name blank is intentional shorthand for "same as the URL" —
    // fill it in here so callers never have to special-case an empty name.
    name: data.name?.trim() || data.url,
  }));

export type TargetFormInput = z.input<typeof targetFormSchema>;
export type TargetFormValues = z.output<typeof targetFormSchema>;
