import type { Metadata } from "next";
import { headers } from "next/headers";
import "./globals.css";

export async function generateMetadata(): Promise<Metadata> {
  const requestHeaders = await headers();
  const host = requestHeaders.get("x-forwarded-host") ?? requestHeaders.get("host") ?? "localhost:3000";
  const protocol = requestHeaders.get("x-forwarded-proto") ?? (host.startsWith("localhost") ? "http" : "https");
  const origin = `${protocol}://${host}`;
  const description = "在 Mac mini 上验证 DJI OM3 BLE 点动控制与 USB 摄像头预览。";

  return {
    title: "OM3 Lab · Mac mini 联调台",
    description,
    openGraph: {
      title: "OM3 Lab · Mac mini 联调台",
      description,
      type: "website",
      images: [{ url: `${origin}/og.png`, width: 1200, height: 630, alt: "OM3 Lab 连接示意" }],
    },
    twitter: {
      card: "summary_large_image",
      title: "OM3 Lab · Mac mini 联调台",
      description,
      images: [`${origin}/og.png`],
    },
  };
}

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="zh-CN">
      <body>{children}</body>
    </html>
  );
}
