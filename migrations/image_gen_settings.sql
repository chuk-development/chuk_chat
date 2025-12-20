-- Migration: Add image generation settings to customization_preferences table
-- Run this in Supabase SQL Editor

-- Add image generation columns to customization_preferences table
ALTER TABLE customization_preferences
ADD COLUMN IF NOT EXISTS image_gen_enabled BOOLEAN DEFAULT false,
ADD COLUMN IF NOT EXISTS image_gen_default_size TEXT DEFAULT 'landscape_4_3',
ADD COLUMN IF NOT EXISTS image_gen_custom_width INTEGER DEFAULT 1024,
ADD COLUMN IF NOT EXISTS image_gen_custom_height INTEGER DEFAULT 768,
ADD COLUMN IF NOT EXISTS image_gen_use_custom_size BOOLEAN DEFAULT false;

-- Add comment for documentation
COMMENT ON COLUMN customization_preferences.image_gen_enabled IS 'Master toggle for AI image generation feature';
COMMENT ON COLUMN customization_preferences.image_gen_default_size IS 'Default size preset: square_hd, square, portrait_4_3, portrait_16_9, landscape_4_3, landscape_16_9';
COMMENT ON COLUMN customization_preferences.image_gen_custom_width IS 'Custom image width (256-2048 pixels)';
COMMENT ON COLUMN customization_preferences.image_gen_custom_height IS 'Custom image height (256-2048 pixels)';
COMMENT ON COLUMN customization_preferences.image_gen_use_custom_size IS 'Use custom dimensions instead of preset sizes';
