import com.example.rtkmanager.*;
import java.nio.*;
import java.nio.file.*;
import java.util.*;

// Run against the actual compiled Android Kotlin classes, without Android or JUnit mocks.
class CaptureFormatsCheck {
    static void check(boolean value, String reason) { if (!value) throw new AssertionError(reason); }
    static void close(double a, double b, double tol, String reason) { check(Math.abs(a-b) <= tol, reason+": "+a+" != "+b); }
    static class Reader {
        final byte[] bytes; int pos = 24;
        Reader(byte[] b) { bytes=b; }
        long u(int n) { long v=0; for(int i=0;i<n;i++,pos++) v=(v<<1)|((bytes[pos/8]>>(7-pos%8))&1); return v; }
        long s(int n) { long v=u(n); return (v&(1L<<(n-1)))!=0 ? v-(1L<<n) : v; }
    }
    static double[] decodeOne(byte[] b, int message, long epoch, boolean more) {
        check((b[0]&255)==211, "RTCM preamble");
        int n=((b[1]&3)<<8)|(b[2]&255);
        check(b.length==n+6, "RTCM length");
        int crc=RtcmMsm7.Companion.crc24q(Arrays.copyOf(b,b.length-3));
        check(crc==((b[b.length-3]&255)<<16 | (b[b.length-2]&255)<<8 | (b[b.length-1]&255)), "CRC24Q");
        Reader r=new Reader(b);
        check(r.u(12)==message, "message type"); check(r.u(12)==0, "station");
        check(r.u(30)==epoch, "epoch"); check(r.u(1)==(more?1:0), "multiple flag");
        check(r.u(18)==0,"reserved header");
        int satellites=Long.bitCount(r.u(64)); int signals=Long.bitCount(r.u(32));
        check(satellites==1 && signals==1 && r.u(1)==1,"single cell masks");
        long rough=r.u(8); r.u(4); long modulo=r.u(10); long rate=r.s(14);
        long range=r.s(20), phase=r.s(24), lock=r.u(10), half=r.u(1), cnr=r.u(10), fineRate=r.s(15);
        double base=(rough+modulo/1024.0)*299792.458;
        return new double[]{base+range*299792.458/Math.pow(2,29),
            phase==-8388608?Double.NaN:base+phase*299792.458/Math.pow(2,31),
            fineRate==-16384?Double.NaN:rate+fineRate*.0001, lock, half, cnr/16.0};
    }
    public static void main(String[] args) throws Exception {
        Path dir=Path.of(args[0]); Files.createDirectories(dir);
        long week=CaptureFormats.WEEK_NS;
        long gps=2400*week+123456000000000L;
        GnssTimeSync clock=new GnssTimeSync();
        check(clock.at(1000)==null,"unanchored clock");
        check(!clock.update(gps, 10000000000L, 2),"initial anchor");
        check(clock.at(10012345678L)==gps+12345678,"sampling timestamp sync");
        check(clock.at(30000000000L)==null,"expired anchor");
        check(clock.update(gps+1000000000L,11000000000L,3),"hardware discontinuity");
        check(clock.update(gps+2006000000L,12000000000L,3),"silent time jump");
        clock.clear(); check(clock.at(12000000000L)==null,"clear anchor");
        long travel=70000000L;
        for(int sys=1;sys<=7;sys++) {
            long shift=sys==3?(10800-18)*1000000000L:sys==5?-14000000000L:0;
            long period=sys==3?CaptureFormats.DAY_NS:week;
            // Reception near time-system week/day rollover.
            long t=2400*week-shift+20000000;
            long sv=Math.floorMod(t+shift-travel,period);
            close(PhoneGnssMath.INSTANCE.pseudorange(t,0,sv,sys,sys==3?128:8,18),20985472.06,.001,"pseudorange system "+sys);
            check(PhoneGnssMath.INSTANCE.pseudorange(t,0,sv,sys,16|8|128,18)==null,"ambiguous millisecond rejection");
        }
        check(PhoneGnssMath.INSTANCE.signal(1,1575420000,"C")==2,"GPS L1C mapping");
        check(PhoneGnssMath.INSTANCE.signal(5,1575420000,"P")==31,"BDS B1C mapping");
        check(PhoneGnssMath.INSTANCE.signal(6,1176450000,"Q")==23,"Galileo E5a mapping");
        double b2aFrequency=1176450048.0; // Android float frequency from the PLG110 capture.
        check(Objects.equals(PhoneGnssMath.INSTANCE.signal(5,b2aFrequency,"Q"),23),"BDS B2a Q compatibility maps to pilot");
        check(Objects.equals(PhoneGnssMath.INSTANCE.signal(5,1176450000,"Q"),23),"BDS B2a nominal frequency compatibility");
        check(PhoneGnssMath.INSTANCE.signal(5,b2aFrequency,"D")==22 &&
            PhoneGnssMath.INSTANCE.signal(5,b2aFrequency,"P")==23 &&
            PhoneGnssMath.INSTANCE.signal(5,b2aFrequency,"X")==24,"standard B2a mappings preserved");
        check(PhoneGnssMath.INSTANCE.signal(5,1207139968,"Q")==15,"BDS B2 Q is not relabeled");
        check(PhoneGnssMath.INSTANCE.signal(5,1561097984,"Q")==3,"BDS B1 Q is not relabeled");
        check(PhoneGnssMath.INSTANCE.signal(5,1575420032,"Q")==null &&
            PhoneGnssMath.INSTANCE.signal(7,b2aFrequency,"Q")==null,"compatibility limited to BDS B2a");
        check(PhoneGnssMath.INSTANCE.signal(5,1176470000,"Q")==null &&
            PhoneGnssMath.INSTANCE.signal(5,Double.NaN,"Q")==null,"compatibility requires a B2a frequency");
        check(PhoneGnssMath.INSTANCE.signal(5,b2aFrequency,"I")==null &&
            PhoneGnssMath.INSTANCE.signal(5,b2aFrequency,"UNKNOWN")==null,"other unknown B2a codes remain unsupported");
        check(PhoneGnssMath.INSTANCE.signal(1,1575420000,"UNKNOWN")==null,"unknown code is not guessed");
        check(RtcmMsm7.Companion.crc24q("123456789".getBytes())==0xcde703,"CRC published check vector");
        check(RtcmMsm7.Companion.lockIndicator(63)==63 && RtcmMsm7.Companion.lockIndicator(64)==64,"lock 64ms boundary");
        check(RtcmMsm7.Companion.lockIndicator(128)==96,"lock 128ms boundary");
        double pr=21000000.25, adr=1234.5, rate=-123.125;
        var b2aQ=new PhoneObservation(5,19,PhoneGnssMath.INSTANCE.signal(5,b2aFrequency,"Q"),b2aFrequency,pr,adr,rate,42.25,25,0);
        var b2aP=new PhoneObservation(5,19,PhoneGnssMath.INSTANCE.signal(5,b2aFrequency,"P"),b2aFrequency,pr,adr,rate,42.25,25,0);
        byte[] b2aPacket=new RtcmMsm7().encode(gps,18,List.of(b2aQ)).getFirst();
        check(Arrays.equals(b2aPacket,new RtcmMsm7().encode(gps,18,List.of(b2aP)).getFirst()),"B2a Q and P produce identical MSM7 observations");
        Reader b2aMask=new Reader(b2aPacket);
        b2aMask.pos+=73+64; // Skip MSM header and satellite mask.
        check(b2aMask.u(32)==(1L<<(32-23)),"B2a pilot MSM signal mask is 23");
        double[] b2aDecoded=decodeOne(b2aPacket,1127,123442000,false);
        close(b2aDecoded[0],pr,.0003,"B2a compatibility preserves pseudorange");
        check(Double.isFinite(b2aDecoded[1]),"B2a compatibility retains valid carrier phase");
        close(b2aDecoded[2],rate,.00005,"B2a compatibility preserves range rate");
        Files.write(dir.resolve("b2a_q_as_p.rtcm3"),b2aPacket);
        var enc=new RtcmMsm7();
        var observation=new PhoneObservation(1,3,2,1575420000,pr,adr,rate,42.25,9,0);
        byte[] b=enc.encode(gps,18,List.of(observation)).getFirst();
        Files.write(dir.resolve("gps.rtcm3"),b);
        double[] d=decodeOne(b,1077,123456000,false);
        close(d[0],pr,.0003,"pseudorange quantization"); close(d[2],rate,.00005,"Doppler rate sign and resolution");
        close(d[5],42.25,.001,"CNR"); check(d[3]==0 && d[4]==0,"new arc and half-cycle");
        double wavelength=299792458.0/1575420000;
        close((d[1]-adr)/wavelength,Math.rint((d[1]-adr)/wavelength),.001,"integer-cycle offset");
        var next=new PhoneObservation(1,3,2,1575420000,pr+rate,adr+rate,rate,42.25,9,0);
        double[] d2=decodeOne(enc.encode(gps+1000000000,18,List.of(next)).getFirst(),1077,123457000,false);
        close(d2[1]-d[1],rate,.0002,"continuous carrier increment"); check(d2[3]>0,"increasing lock");
        var slip=new PhoneObservation(1,3,2,1575420000,pr+2*rate,adr+2*rate,rate,42.25,13,0);
        check(decodeOne(enc.encode(gps+2000000000,18,List.of(slip)).getFirst(),1077,123458000,false)[3]==0,"cycle slip resets lock");
        var missing=new PhoneObservation(1,3,2,1575420000,pr,null,null,0,0,0);
        d=decodeOne(enc.encode(gps,18,List.of(missing)).getFirst(),1077,123456000,false);
        check(Double.isNaN(d[1]) && Double.isNaN(d[2]),"missing measurements encoded invalid");
        var zero=new PhoneObservation(1,3,2,1575420000,299792.458*70,0.0,0.0,0,9,0);
        d=decodeOne(new RtcmMsm7().encode(gps,18,List.of(zero)).getFirst(),1077,123456000,false);
        close(d[0],zero.getRange(),.001,"zero pseudorange residual is valid"); check(d[2]==0,"zero Doppler is valid");
        var systems=new ArrayList<PhoneObservation>();
        for(int sys=1;sys<=7;sys++) systems.add(new PhoneObservation(sys,3,sys==7?22:2,
            sys==7?1176450000:sys==3?1602000000:sys==5?1561098000:1575420000,pr,adr,rate,40,9,0));
        var packets=new RtcmMsm7().encode(gps,18,systems);
        int[] types={1077,1107,1087,1117,1127,1097,1137};
        var all=new java.io.ByteArrayOutputStream();
        for(int i=0;i<packets.size();i++) {
            long ms=123456000;
            if(i==2) { ms+= (10800-18)*1000; ms=((ms/86400000)<<27)+ms%86400000; }
            if(i==4) ms-=14000;
            decodeOne(packets.get(i),types[i],ms,i<6); all.write(packets.get(i));
        }
        Files.write(dir.resolve("multi.rtcm3"),all.toByteArray());
        var many=new ArrayList<PhoneObservation>();
        for(int sat=1;sat<=40;sat++) for(int sig:new int[]{2,22,23}) many.add(new PhoneObservation(1,sat,sig,1575420000,pr,adr,rate,40,9,0));
        var split=new RtcmMsm7().encode(gps,18,many);
        check(split.size()==2,"large mask is split into <=64 cells");
        for(byte[] packet:split) check(packet.length<=1029,"RTCM maximum length");
        var sensor=new java.io.ByteArrayOutputStream();
        for(int id:new int[]{0x10,0x20,0x30}) {
            byte[] frame=CaptureFormats.INSTANCE.sensorFrame(65535,gps+123456789,18,id,
                id==0x10?new float[]{9.80665f,0,-9.80665f}:id==0x20?new float[]{(float)Math.PI,0,0}:new float[]{10.25f,-20.5f,0});
            check(frame.length==52 && (frame[4]&255)==45,"sensor frame length");
            int a=0,c=0; for(int k=2;k<50;k++) { a=(a+(frame[k]&255))&255;c=(c+a)&255; }
            check(a==(frame[50]&255) && c==(frame[51]&255),"sensor checksum");
            ByteBuffer p=ByteBuffer.wrap(frame).order(ByteOrder.LITTLE_ENDIAN);
            check(p.getShort(40)==2400 && p.getLong(42)==123456123456789L,"GPST TLV nanoseconds");
            if(id==0x10) check(p.getInt(7)==1000000,"acceleration g units");
            if(id==0x20) check(Math.abs(p.getInt(7)-180000000)<10,"gyro deg/s units");
            sensor.write(frame);
        }
        Files.write(dir.resolve("sensors.bin"),sensor.toByteArray());
        byte[] combined=CaptureFormats.INSTANCE.imuFrame(42,gps+123456789,18,
            new float[]{9.80665f,0,-9.80665f},new float[]{(float)Math.PI,0,0});
        check(combined.length==66 && (combined[4]&255)==59,"six axes in a single frame");
        check(combined[5]==0x10 && combined[19]==0x20,"accel and gyro TLVs together");
        int ca=0,cb=0; for(int k=2;k<combined.length-2;k++) { ca=(ca+(combined[k]&255))&255;cb=(cb+ca)&255; }
        check(ca==(combined[64]&255) && cb==(combined[65]&255),"combined checksum");
        Files.write(dir.resolve("imu_paired.bin"),combined);
        for(int hz:new int[]{25,50,100,200}) {
            long period=1000000000L/hz;
            var pairer=new ImuSamplePairer(period/2);
            var rateTracker=new SensorSampleRate();
            int pairs=0;
            // Same-sensor callback bursts, phase offset and small timestamp jitter.
            for(int block=0;block<10;block++) {
                for(int i=0;i<10;i++) pairer.add("accel",10000000000L+(block*10+i)*period,new float[]{i,2,3});
                for(int i=0;i<10;i++) {
                    long ts=10000000000L+(block*10+i)*period+period/4+(i%2)*10000;
                    var paired=pairer.add("gyro",ts,new float[]{4,5,6});
                    for(var p:paired) {
                        check(Math.abs(p.getAccel().getTimestamp()-p.getGyro().getTimestamp())<=period/2,"bounded pairing skew");
                        close(p.getAccel().getValues()[0],i,0,"no sample duplication");
                        rateTracker.add(p.getGyro().getTimestamp()); pairs++;
                    }
                }
            }
            pairer.finish(); check(pairs==100 && pairer.getDropped()==0,"all IMU pairs at "+hz);
            close(rateTracker.averageHz(),hz,.1,"measured frequency from sensor time");
            check(rateTracker.hz(20000000000L)==0,"stale stream reports zero Hz");
        }
        var pairer=new ImuSamplePairer(5000000);
        pairer.add("accel",10000000,new float[]{1,2,3});
        check(pairer.add("gyro",30000000,new float[]{4,5,6}).isEmpty(),"never pair stale sensors");
        check(pairer.getDropped()==1,"unmatched sample counted");
        check(pairer.add("accel",32000000,new float[]{7,8,9}).size()==1,"recover after missing sample");
        check(pairer.add("gyro",30000000,new float[]{4,5,6}).isEmpty(),"reject duplicate timestamp");
        pairer.add("accel",40000000,new float[]{1,2,3}); pairer.finish();
        check(pairer.getDropped()==3,"pending sample counted on stop");
        var rate50=new SensorSampleRate();
        for(int i=0;i<100;i++) rate50.add(10000000000L+i*20000000L);
        close(rate50.hz(12000000000L),50,0.0001,"magnetic 50 Hz remains 50 Hz regardless of request");
        System.out.println("Native clock, pseudorange, MSM7, phase arcs, CRC and sensor frame checks passed.");
    }
}
