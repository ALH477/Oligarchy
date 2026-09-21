  custom.locale = {
    language = "en-US";
    # LC_TIME=de_DE.UTF-8 disagrees with LANG=en_US.UTF-8: keep the UI
    # language above, take date/number/paper formats from this one instead.
    # (LC_TIME reads "de_DE.utf8" on that machine; normalised to the spelling
    # NixOS' well-formedness check accepts.)
    region = "de_DE.UTF-8";
  };
