// Aula -- the hall: five mono sections in, stereo out. Seating (pan) and
// balance, a Zita reverb for the room, and a limiter so the culmen cannot
// clip -- driven at half level, so it catches peaks and leaves the
// crescendo alone. Input order is the score's track order: ostinatum, aes, scurra,
// fagottus, tympanum.
declare name "aula";
import("stdfaust.lib");

sede(l, p) = *(l) <: *(sqrt(1 - p)), *(sqrt(p));

ordo = sede(0.95, 0.40),   // ostinatum: left of centre, the strings' side
       sede(0.85, 0.60),   // aes: right, the brass
       sede(0.75, 0.30),   // scurra: the jester, far forward left
       sede(0.90, 0.68),   // fagottus
       sede(1.00, 0.50)    // tympanum: centre back
       :> _, _;

aula = _, _ <: _, _, (re.zita_rev1_stereo(20, 200, 6000, 3.4, 2.6, 48000) : *(0.28), *(0.28)) :> _, _;

process = ordo : *(0.5), *(0.5) : aula : co.limiter_1176_R4_stereo;
