local Settings = {
  ALWAYS_SYNC = "always_sync",
  BOOKS = "books",
  COMPATIBILITY_MODE = "compatibility_mode",
  ENABLE_WIFI = "enable_wifi",
  LINK_BY_HARDCOVER = "link_by_hardcover",
  LINK_BY_ISBN = "link_by_isbn",
  LINK_BY_TITLE = "link_by_title",
  MENU_CONFIRMATION = "menu_confirmation",
  SHELF_SORT = "shelf_sort",
  SYNC = "sync",
  TRACK_FREQUENCY = "track_frequency",
  TRACK_METHOD = "track_method",
  TRACK_PERCENTAGE = "track_percentage",
  TRACK = {
    FREQUENCY = "frequency",
    PROGRESS = "progress",
  },
  UPDATE_AVAILABLE = "update_available",
  SHOW_FOR_YOU = "show_for_you",
  UPDATE_BETA = "update_beta",
  UPDATE_CHECK = "update_check",
  UPDATE_LAST_CHECK = "update_last_check",
  USER_ID = "user_id",
  USER_NAME = "user_name",
}

Settings.AUTOLINK_OPTIONS = { Settings.LINK_BY_HARDCOVER, Settings.LINK_BY_ISBN, Settings.LINK_BY_TITLE }

return Settings
