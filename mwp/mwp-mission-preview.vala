/*
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 * (c) Jonathan Hudson <jh+mwptools@daria.co.uk>
 */

public struct HomePos
{
    double hlat;
    double hlon;
    bool valid;
}

public class MissionReplayThread : GLib.Object
{
    public enum Mode
    {
        CHECK = 0,
        REPLAY = 1,
        TEST = 2
    }

    private const int MAXSLEEP = 20*1000; // 10 time speedup
    private const double MSPEED = 10.0;
    private const double MHERTZ = 5.0; // nominal reporting rate
    private const double NM2METRES = 1852.0;
    public signal void mission_check_event(int p1, int p2, double cse, double d, double dx);
    public signal void mission_replay_event(double lat, double lon, double cse);
    public signal void mission_replay_done();

    private bool running = false;
    private bool warmup = false;
    private double speed = MSPEED;
    private double dist = 0.0;
    private MissionItem[] mi;
    private Mode mode;

    public bool is_mr = false;
    public bool multijump = true;

    public bool indet { get; private set; default = false; }

    private struct JumpCounter
    {
        int idx;
        int count;
    }

    public void stop()
    {
        running = false;
    }

    private void outloc (double lat, double lon, double cse)
    {
        mission_replay_event(lat, lon,cse);
        Thread.usleep(MAXSLEEP);
    }

    private double fly_leg (double slat, double slon,
                            double elat, double elon)
    {
        double c,d;
        Geo.csedist(slat,slon,elat,elon,out d, out c);
        d *= NM2METRES;
        dist += d;

        if (!warmup)
        {
            int steps = (int)(Math.round(MHERTZ * d / speed));
            var delta = speed / 5.0 / NM2METRES;

            for(var i = 0; running && i < steps; i++)
            {
                Geo.posit(slat, slon, c, delta, out slat, out slon);
                outloc (slat, slon, c);
            }
        }
        return c;
    }

/*
  Given a location cy,cx
  calculate a PH with radius and time
  assuming we continue on course for radius, then circle
  return final position
*/

    private void iterate_ph (double cy, double cx, double brg,
                             int phtim, out double ry, out double rx)
    {
        const double RADIUS = 35.0;
        ry = cy;
        rx = cx;
        if (phtim > 0)
        {
            if(!warmup)
            {
                var simwait = phtim / speed;
                Timer timer = new Timer ();
                if(is_mr)
                {
                    while (running && timer.elapsed (null) < simwait)
                    {
                        Thread.usleep(MAXSLEEP);
                    }
                }
                else
                {
                    const double DEGINC = 5;
                    const double SECS_CIRC = 2*Math.PI*RADIUS/MSPEED;
                    const double RNM = RADIUS / NM2METRES;
                    Geo.posit(cy, cx, brg, RNM, out ry, out rx);
                    fly_leg(cy,cx, ry, rx);
                    var lx = rx;
                    var ly = ry;
                    var bcnt = 0;
                    var maxbcnt = (int) (phtim*360/SECS_CIRC/DEGINC);
                    while (running && bcnt < maxbcnt)
                    {
                        double c,d;
                        brg += DEGINC;
                        brg = brg % 360.0;
                        Geo.posit(cy, cx, brg, RNM, out ry, out rx);
                        Geo.csedist(ly,lx,ry,rx, out d, out c);
                        lx = rx;
                        ly = ry;
                        outloc (ry, rx, c);
                        bcnt++;
                    }
                }
                timer.stop ();
            }
            else
            {
                if(!is_mr)
                    dist += (phtim * speed);
            }
        }
    }

    private void iterate_mission (MissionItem [] mi, HomePos h)
    {
	var ret = false;
        var n = 0;
        var lastn = 0;
        var nsize = mi.length;
        var lx = 0.0;
        var ly = 0.0;
        var valid = false;
        var cse = 0.0;
        var cx = 0.0;
        var cy = 0.0;

        JumpCounter [] jump_counts = {};

        if(multijump)
        {
            for (var i = 0; i < mi.length; i++)
            {
                if(mi[i].action == MSP.Action.JUMP)
                {
                    JumpCounter jc = {i, mi[i].param2};
                    jump_counts += jc;
                }
            }
        }


        for (;;)
        {
            if (n == nsize)
                break;

            var typ = mi[n].action;

            if (typ == MSP.Action.SET_POI || typ == MSP.Action.SET_HEAD)
            {
                n += 1;
                continue;
            }

            if (valid)
            {
                if (typ == MSP.Action.JUMP)
                {
                    if (mi[n].param2 == -1)
                    {
                        indet = true;
                        if (warmup)
                        {
                            n += 1;
                        }
                        else
                            n = (int)mi[n].param1 - 1;
                    }
                    else
                    {
                        if (mi[n].param2 == 0)
                        {
                            if(multijump)
                            {
                                foreach(var jc in jump_counts)
                                {
                                    if(n == jc.idx)
                                    {
                                        mi[n].param2 = jc.count;
                                        break;
                                    }
                                }
                            }
                            n += 1;
                        }
                        else
                        {
                            mi[n].param2 -= 1;
                            n = (int)mi[n].param1 - 1;
                        }

                    }
                    continue;
                }

                if (typ == MSP.Action.RTH)
                {
                    ret = true;
                    break;
                }

                cy = mi[n].lat;
                cx = mi[n].lon;
                double d;
                Geo.csedist(ly,lx,cy,cx, out d, out cse);
                var nc = fly_leg(ly,lx,cy,cx);
                if(warmup && ((mode & Mode.REPLAY) == 0))
                    mission_check_event(lastn, n, cse, d*NM2METRES, dist);

                if (nc != -1)
                    cse = nc;

                    // handle PH
                if  (typ == MSP.Action.POSHOLD_TIME ||
                     typ == MSP.Action.POSHOLD_UNLIM)
                {
                    var phtim = (int)mi[n].param1;
                        // really we need cse from start ... in case wp1 is PH
                    if  (typ == MSP.Action.POSHOLD_UNLIM)
                        phtim = -1;

                    if (phtim == -1 || phtim > 5)
                        iterate_ph(cy, cx, cse, phtim, out cy, out cx);
                }
                lastn = n;
                n += 1;
            }
            else
            {
                cy = mi[n].lat;
                cx = mi[n].lon;
                valid = true;
                n += 1;
            }
            lx = cx;
            ly = cy;
            if(!running)
                break;
        }

	if (running && ret && h.valid)
        {
            if(warmup && ((mode & Mode.REPLAY) == 0))
            {
                double d;
                Geo.csedist(cy,cx,h.hlat, h.hlon, out d, out cse);
                mission_check_event(lastn, 255, cse, d*NM2METRES, dist);
            }
            fly_leg(cy,cx,h.hlat,h.hlon);
            cy = h.hlat;
            cx = h.hlon;
        }
    }

    public Thread<int> run_mission (Mission m, HomePos h, Mode _mode)
    {
        running = true;
        var thr = new Thread<int> ("preview", () => {
                bool [] passes = {true, false};

                mode = _mode;
                foreach (var p in passes)
                {
                    warmup = p;
                    mi = m.get_ways();
                    dist = 0.0;
                    if(h.valid)
                    {
                        var cse = fly_leg(h.hlat, h.hlon, mi[0].lat, mi[0].lon);
                        if(warmup)
                            mission_check_event(255, 0, cse, dist, dist);
                    }
                    if(running && mi.length > 1)
                        iterate_mission(mi, h);
                    if(p)
                    {
                        if(mode == Mode.CHECK)
                            break;

                        if (dist < 3000)
                            speed = MSPEED;
                        else
                            speed = (dist/3000) * MSPEED;
                    }
                }
                mission_replay_done();
                return 0;
            });
        return thr;
    }

#if PREVTEST
    public string fmtwp(int n)
    {
        string s;
        var typ = mi[n].action;

        if(n == 255)
            s = "Home";
        else
        {
            n += 1;
            if(typ == MSP.Action.JUMP)
                s = "(J%02d)".printf(n);
            else if (typ == MSP.Action.POSHOLD_TIME)
                s = "PH%02d".printf(n);
            else
                s = "WP%02d".printf(n);

        }
        return s;
    }

    private static bool nohome = false;
    private static bool mr = false;
    private static bool nmj = false;
    private static bool checker = false;

    const OptionEntry[] options = {
        { "nohome", '0', 0, OptionArg.NONE, out nohome, "No home", null},
        { "multi-rotor", 'm', 0, OptionArg.NONE, out mr, "mr mode", null},
        { "no-multi-jump", 'n', 0, OptionArg.NONE, out nmj, "single jump", null},
        { "check", 'c', 0, OptionArg.NONE, out checker, "check only", null},
        {null}
    };

    public static int main (string[] args)
    {

        try {
            var opt = new OptionContext(" - test args");
            opt.set_help_enabled(true);
            opt.add_main_entries(options, null);
            opt.parse(ref args);
        }
        catch (OptionError e) {
            stderr.printf("Error: %s\n", e.message);
            stderr.printf("Run '%s --help' to see a full list of available "+
                          "options\n", args[0]);
            return 1;
        }

        Mission ms;

        if ((ms = XmlIO.read_xml_file (args[1])) != null)
        {

            HomePos h = { 50.8047104, -1.4942621, true };

            h.valid = !nohome;

            var ml = new MainLoop();
            var mt = new MissionReplayThread();

            mt.is_mr = mr;
            mt.multijump = !nmj;

            mt.mission_replay_event.connect((la,lo,co) => {
                    stderr.printf("pos %f %f %.1f\n", la, lo, co);
                });

            mt.mission_check_event.connect((p1,p2,co,d,dx) => {
                    StringBuilder sb = new StringBuilder();
                    sb.append(mt.fmtwp(p1));
                    if(p1 > p2) // JUMPING
                    {
                        sb.append(" ");
                        sb.append(mt.fmtwp(p1+1));
                        sb.append(" ");
                    }
                    else
                        sb.append(" - ");
                    sb.append(mt.fmtwp(p2));
                    sb.append_printf("\t%03.0f° %4.0fm %5.0fm\n", co, d, dx);
                    stdout.puts(sb.str);
                });

            mt.mission_replay_done.connect(() => {
                    ml.quit();
                });

            Thread<int> thr = null;

            var mode = (checker) ?  MissionReplayThread.Mode.CHECK :
                MissionReplayThread.Mode.TEST;

            Idle.add(() => {
                    thr = mt.run_mission(ms, h, mode);
                    return false;
                });
            ml.run();
            thr.join();
        }
        return 0;
    }
#endif
}
