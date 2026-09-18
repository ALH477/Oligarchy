{ ... }:
{
  custom.scrollmapper = {
    enable = true;
    translation = "KJVA";
    canon = "orthodox";
    wrap = 72;
    aliases = false;

    bootDialogue = {
      enable = true;
      plymouth = true;
      console = true;
      bootIntro = true;
    };

    dailyVerse = {
      enable = true;
      onLogin = true;
      notify = false;
      hour = 7;
      fullCanon = false;
    };
  };
}
