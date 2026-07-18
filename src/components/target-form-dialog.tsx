import { useEffect } from "react";
import { Controller, useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import {
  Dialog,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Switch } from "@/components/ui/switch";
import {
  targetFormSchema,
  type TargetFormInput,
  type TargetFormValues,
} from "@/lib/schemas";
import { useTranslation } from "@/lib/i18n/context";
import type { Target } from "@/types/target";

const defaultValues: TargetFormInput = {
  name: "",
  url: "",
  group_tag: "",
  check_interval_secs: 300,
  check_http: true,
  expected_status: 200,
  check_ssl: true,
  check_domain: false,
  custom_path: "",
  expected_body_contains: "",
};

interface TargetFormDialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  editingTarget: Target | null;
  onSubmit: (values: TargetFormValues) => Promise<void>;
}

export function TargetFormDialog({
  open,
  onOpenChange,
  editingTarget,
  onSubmit,
}: TargetFormDialogProps) {
  const { t } = useTranslation();
  const {
    register,
    handleSubmit,
    control,
    reset,
    formState: { errors, isSubmitting },
  } = useForm<TargetFormInput, unknown, TargetFormValues>({
    resolver: zodResolver(targetFormSchema),
    defaultValues,
  });

  useEffect(() => {
    if (open) {
      reset(
        editingTarget
          ? {
              name: editingTarget.name,
              url: editingTarget.url,
              group_tag: editingTarget.group_tag ?? "",
              check_interval_secs: editingTarget.check_interval_secs,
              check_http: editingTarget.check_http,
              expected_status: editingTarget.expected_status,
              check_ssl: editingTarget.check_ssl,
              check_domain: editingTarget.check_domain,
              custom_path: editingTarget.custom_path ?? "",
              expected_body_contains: editingTarget.expected_body_contains ?? "",
            }
          : defaultValues,
      );
    }
  }, [open, editingTarget, reset]);

  const submit = handleSubmit(async (values) => {
    await onSubmit(values);
    onOpenChange(false);
  });

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle>{editingTarget ? t("form.editTitle") : t("form.addTitle")}</DialogTitle>
        </DialogHeader>

        <form onSubmit={submit} className="flex flex-col gap-4">
          <div className="grid gap-1.5">
            <Label htmlFor="name">{t("form.name")}</Label>
            <Input id="name" placeholder="Main Site" {...register("name")} />
            {errors.name && <p className="text-xs text-destructive">{errors.name.message}</p>}
          </div>

          <div className="grid gap-1.5">
            <Label htmlFor="url">{t("form.url")}</Label>
            <Input id="url" placeholder="https://example.com" {...register("url")} />
            {errors.url && <p className="text-xs text-destructive">{errors.url.message}</p>}
          </div>

          <div className="grid gap-1.5">
            <Label htmlFor="group_tag">{t("form.group")}</Label>
            <Input id="group_tag" placeholder="Northwind" {...register("group_tag")} />
          </div>

          <div className="grid gap-1.5">
            <Label htmlFor="check_interval_secs">{t("form.interval")}</Label>
            <Input
              id="check_interval_secs"
              type="number"
              {...register("check_interval_secs")}
            />
            {errors.check_interval_secs && (
              <p className="text-xs text-destructive">{errors.check_interval_secs.message}</p>
            )}
          </div>

          <div className="flex items-center justify-between rounded-lg border p-3">
            <div className="flex flex-col gap-0.5">
              <Label htmlFor="check_http">{t("form.checkHttp")}</Label>
            </div>
            <Controller
              control={control}
              name="check_http"
              render={({ field }) => (
                <Switch id="check_http" checked={field.value} onCheckedChange={field.onChange} />
              )}
            />
          </div>

          <div className="grid gap-1.5">
            <Label htmlFor="expected_status">{t("form.expectedStatus")}</Label>
            <Input id="expected_status" type="number" {...register("expected_status")} />
          </div>

          <div className="grid gap-1.5">
            <Label htmlFor="custom_path">{t("form.customPath")}</Label>
            <Input id="custom_path" placeholder="/health" {...register("custom_path")} />
          </div>

          <div className="grid gap-1.5">
            <Label htmlFor="expected_body_contains">{t("form.expectedBody")}</Label>
            <Input
              id="expected_body_contains"
              placeholder="&quot;status&quot;:&quot;ok&quot;"
              {...register("expected_body_contains")}
            />
          </div>

          <div className="flex items-center justify-between rounded-lg border p-3">
            <Label htmlFor="check_ssl">{t("form.checkSsl")}</Label>
            <Controller
              control={control}
              name="check_ssl"
              render={({ field }) => (
                <Switch id="check_ssl" checked={field.value} onCheckedChange={field.onChange} />
              )}
            />
          </div>

          <div className="flex items-center justify-between rounded-lg border p-3">
            <Label htmlFor="check_domain">{t("form.checkDomain")}</Label>
            <Controller
              control={control}
              name="check_domain"
              render={({ field }) => (
                <Switch id="check_domain" checked={field.value} onCheckedChange={field.onChange} />
              )}
            />
          </div>

          <DialogFooter>
            <Button type="submit" disabled={isSubmitting}>
              {editingTarget ? t("form.save") : t("form.add")}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
