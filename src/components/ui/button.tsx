import * as React from "react"
import { cva, type VariantProps } from "class-variance-authority"
import { cn } from "cn"
import { Slot } from "radix-ui"

const buttonVariants = cva(
  "group/button inline-flex shrink-0 items-center justify-center rounded-xl border border-transparent bg-clip-padding text-sm font-semibold whitespace-nowrap transition-all outline-none select-none focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/50 active:not-aria-[haspopup]:translate-y-px disabled:pointer-events-none disabled:opacity-50 aria-invalid:border-destructive aria-invalid:ring-3 aria-invalid:ring-destructive/20 dark:aria-invalid:border-destructive/50 dark:aria-invalid:ring-destructive/40 [&_svg]:pointer-events-none [&_svg]:shrink-0 [&_svg:not([class*='size-'])]:size-4",
  {
    variants: {
      variant: {
        // Botão "de jogo": degradê roxo-magenta com borda 3D que afunda ao clicar.
        default:
          "bg-linear-to-b from-[oklch(0.7_0.23_315)] to-[oklch(0.55_0.24_298)] font-heading text-[1.02em] tracking-wide text-primary-foreground shadow-[inset_0_1px_0_oklch(1_0_0/0.3),0_4px_0_oklch(0.36_0.17_295),0_10px_22px_-8px_oklch(0.6_0.24_305/0.7)] [text-shadow:0_1px_1px_oklch(0_0_0/0.35)] hover:brightness-110 active:not-aria-[haspopup]:translate-y-[3px] active:not-aria-[haspopup]:shadow-[inset_0_1px_0_oklch(1_0_0/0.3),0_1px_0_oklch(0.36_0.17_295)]",
        // Dourado: a ação principal da tela (criar, começar, revanche).
        gold:
          "bg-linear-to-b from-[oklch(0.9_0.15_92)] to-[oklch(0.76_0.16_70)] font-heading text-[1.02em] tracking-wide text-gold-foreground shadow-[inset_0_1px_0_oklch(1_0_0/0.6),0_4px_0_oklch(0.52_0.13_60),0_10px_24px_-8px_oklch(0.8_0.16_80/0.65)] hover:brightness-105 active:not-aria-[haspopup]:translate-y-[3px] active:not-aria-[haspopup]:shadow-[inset_0_1px_0_oklch(1_0_0/0.6),0_1px_0_oklch(0.52_0.13_60)]",
        outline:
          "border-white/12 bg-white/[0.04] hover:border-white/20 hover:bg-white/[0.09] aria-expanded:bg-white/[0.09]",
        secondary:
          "bg-white/[0.08] text-secondary-foreground hover:bg-white/[0.13] aria-expanded:bg-white/[0.13]",
        ghost:
          "hover:bg-white/[0.08] hover:text-foreground aria-expanded:bg-white/[0.08]",
        destructive:
          "border-destructive/30 bg-destructive/15 text-[oklch(0.8_0.14_25)] hover:bg-destructive/25 focus-visible:border-destructive/40 focus-visible:ring-destructive/30",
        link: "text-primary underline-offset-4 hover:underline",
      },
      size: {
        default:
          "h-9 gap-1.5 px-3.5 has-data-[icon=inline-end]:pr-2 has-data-[icon=inline-start]:pl-2",
        xs: "h-6 gap-1 rounded-[min(var(--radius-md),10px)] px-2 text-xs in-data-[slot=button-group]:rounded-lg has-data-[icon=inline-end]:pr-1.5 has-data-[icon=inline-start]:pl-1.5 [&_svg:not([class*='size-'])]:size-3",
        sm: "h-7 gap-1 rounded-[min(var(--radius-md),12px)] px-2.5 text-[0.8rem] in-data-[slot=button-group]:rounded-lg has-data-[icon=inline-end]:pr-1.5 has-data-[icon=inline-start]:pl-1.5 [&_svg:not([class*='size-'])]:size-3.5",
        lg: "h-11 gap-2 px-5 text-base has-data-[icon=inline-end]:pr-2 has-data-[icon=inline-start]:pl-2",
        icon: "size-9",
        "icon-xs":
          "size-6 rounded-[min(var(--radius-md),10px)] in-data-[slot=button-group]:rounded-lg [&_svg:not([class*='size-'])]:size-3",
        "icon-sm":
          "size-7 rounded-[min(var(--radius-md),12px)] in-data-[slot=button-group]:rounded-lg",
        "icon-lg": "size-10",
      },
    },
    defaultVariants: {
      variant: "default",
      size: "default",
    },
  }
)

function Button({
  className,
  variant = "default",
  size = "default",
  asChild = false,
  ...props
}: React.ComponentProps<"button"> &
  VariantProps<typeof buttonVariants> & {
    asChild?: boolean
  }) {
  const Comp = asChild ? Slot.Root : "button"

  return (
    <Comp
      data-slot="button"
      data-variant={variant}
      data-size={size}
      className={cn(buttonVariants({ variant, size, className }))}
      {...props}
    />
  )
}

export { Button, buttonVariants }
