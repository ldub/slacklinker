{-# LANGUAGE TemplateHaskell #-}

module Slacklinker.Settings.Types where

import Slacklinker.Import
import Slacklinker.PersistImport

data SlacklinkerSetting (a :: SlacklinkerSettingTag) where
  -- | Whether to allow any access to register new workspaces.
  SettingAllowRegistration :: Bool -> SlacklinkerSetting 'AllowRegistration
  -- | Not implemented yet!
  SettingRequireMutualTLS :: Bool -> SlacklinkerSetting 'RequireMutualTLS

data SlacklinkerSettingTag = AllowRegistration | RequireMutualTLS
  deriving stock (Show, Eq, Ord, Enum, Bounded, Generic, Read)

$(derivePostgresEnumForSumType ''SlacklinkerSettingTag "slacklinker_setting_tag")
