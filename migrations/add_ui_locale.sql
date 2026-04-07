-- ============================================================
-- Migration: Add ui_locale column to customization_preferences
-- ============================================================
-- Stores the user's preferred UI language ('en' or 'de').
-- Default is 'en' (English).
--
-- Run in Supabase Dashboard → SQL Editor
-- ============================================================

ALTER TABLE customization_preferences
  ADD COLUMN IF NOT EXISTS ui_locale TEXT NOT NULL DEFAULT 'en';
