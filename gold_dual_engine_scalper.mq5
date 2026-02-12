//+------------------------------------------------------------------+
//|  GoldDualEngineRegimeEA.mq5                                      |
//|  Regime-based dual-engine scalping EA for XAUUSD (Gold)          |
//|  Implements continuation burst and liquidity sweep reversal      |
//|  engines via an explicit state machine.                          |
//+------------------------------------------------------------------+
#property strict
#property copyright "Mithun"
#property link      "https://www.ororasoft.com"
#property version   "1.00"
#property description "Regime-based dual-engine scalping EA for XAUUSD (Gold)"

//--- include standard trade class
#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Helper: normalize datetime to start of day (server time)         |
//| This replaces pseudo-code DateOfDay(...) used throughout.        |
//+------------------------------------------------------------------+
datetime DateOfDay(datetime t)
  {
   MqlDateTime s;
   TimeToStruct(t,s);
   s.hour = 0;
   s.min  = 0;
   s.sec  = 0;
   return(StructToTime(s));
  }

//+------------------------------------------------------------------+
//| ENUMS AND BASIC TYPES                                            |
//+------------------------------------------------------------------+

//--- trading side
enum ESide
  {
   SIDE_NONE = 0,
   SIDE_BUY  = 1,
   SIDE_SELL = -1
  };

//--- regime states
enum EState
  {
   STATE_IDLE = 0,
   STATE_COMPRESSION,
   STATE_BURST_CONTINUATION,
   STATE_LIQUIDITY_SWEEP,
   STATE_COOLDOWN
  };

//--- engine types
enum EEngineType
  {
   ENGINE_NONE = 0,
   ENGINE_CONTINUATION,
   ENGINE_REVERSAL
  };

//--- liquidity zone type
enum ELiquidityZoneType
  {
   LQT_NONE = 0,
   LQT_EQUAL_HIGH,
   LQT_EQUAL_LOW,
   LQT_SESSION_HIGH,
   LQT_SESSION_LOW,
   LQT_ASIAN_HIGH,
   LQT_ASIAN_LOW,
   LQT_SWING_HIGH,
   LQT_SWING_LOW
  };

//+------------------------------------------------------------------+
//| CONFIGURATION STRUCTS                                            |
//+------------------------------------------------------------------+

//--- volatility burst configuration
struct SBurstConfig
  {
   double  rangeMultiplier;   // factor for CurrentRange > SMA(Range,20)*factor
   double  volumeMultiplier;  // factor for Volume > SMA(Volume,20)*factor
   double  bodyRatioMin;      // minimum body ratio
   int     lookback;          // SMA period, default 20
  };

//--- compression detection configuration (structure TF = M15)
struct SCompressionConfig
  {
   int     atrPeriod;         // ATR period for compression check
   double  atrCompressionFactor; // ATR < avgATR * factor implies compression
   int     windowBars;        // number of bars considered for compression window
  };

//--- liquidity zone detection configuration
struct SLiquidityZoneConfig
  {
   double  equalHighLowTolerancePoints; // tolerance in points to cluster equal highs/lows
   int     swingLookbackBars;           // lookback for swing high/low detection
   int     asianSessionStartHour;       // broker time
   int     asianSessionEndHour;         // broker time
  };

//--- sweep detection configuration
struct SSweepConfig
  {
   double  wickBodyRatioMin;     // minimum wick/body ratio
   double  volumeSpikeMultiplier;// volume > SMA(volume)*multiplier
   int     volumeLookback;       // SMA period for volume
   int     structureTf;          // timeframe used for structure confirmation
  };

//--- exhaustion math configuration
struct SExhaustionConfig
  {
   double  minScore;             // minimum exhaustion score to accept reversal
   int     rangeLookback;        // bars used in range component
   int     volumeLookback;       // bars used in volume anomaly
  };

//--- divergence configuration (RSI based)
struct SDivergenceConfig
  {
   int     rsiPeriod;
   int     priceSwingLookback;
   int     rsiSwingLookback;
   bool    useDivergence;        // enable / disable divergence filter
  };

//--- risk configuration
struct SRiskConfig
  {
   double  riskPerTradePct;      // e.g. 0.25
   double  maxDailyLossPct;      // e.g. 2.0
   int     maxConcurrentTrades;  // should be 1
   double  reversalRiskFactor;   // <1 to scale risk for reversal trades
  };

//--- news filter configuration
struct SNewsConfig
  {
   int     minutesBeforeRed;     // 15
   int     minutesAfterRed;      // 10
   bool    enableNewsFilter;
  };

//--- session filter configuration
struct SSessionConfig
  {
   int     londonStartHour;      // broker time
   int     londonEndHour;
   int     nyStartHour;
   int     nyEndHour;
   bool    disableAsian;         // true to avoid Asian dead session
  };

//--- engine thresholds and timeouts
struct SEngineThresholds
  {
   // continuation engine
   int     contImpulseBars;      // bars to define impulse
   int     contPullbackBars;     // bars to define micro pullback
   int     contTimeStopMinutes;  // max minutes to hold continuation trades
   // reversal engine
   int     revTimeStopMinutes;   // max minutes to hold reversal trades
   double  tp1PartialCont;       // portion to close at TP1 (0.3-0.4)
   double  tp1PartialRev;        // portion to close at TP1 (0.5-0.6)
  };

//--- generic feature snapshot shared between modules and state machine
struct SFeatureSnapshot
  {
   datetime time;
   bool     isCompression;
   bool     justExitedCompression;
   bool     isBurst;
   double   vwap;
   double   vwapSlope;
   bool     vwapFlat;
   double   vwma;
   int      vwmaDirection;       // -1,0,1
   bool     hasSweep;
   int      sweepDirection;      // SIDE_BUY/SIDE_SELL
   int      sweepZoneIndex;
   double   exhaustionScore;
   bool     exhaustionOk;
   bool     bullishDivergence;
   bool     bearishDivergence;
   bool     sessionAllowed;
   bool     newsBlocked;
   bool     dailyRiskLocked;
  };

//--- execution request from logic engine to trade layer
struct SExecutionRequest
  {
   bool           shouldOpen;
   ENUM_ORDER_TYPE orderType;
   double         entryPrice;
   double         slPrice;
   double         tp1Price;
   double         tp2Price;
   EEngineType    engine;
  };

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                 |
//+------------------------------------------------------------------+

input string InpSection1_Risk           = "=== Risk Settings ===";
input double InpRiskPerTradePct         = 0.25;
input double InpMaxDailyLossPct         = 2.0;
input int    InpMaxConcurrentTrades     = 1;
input double InpReversalRiskFactor      = 0.8;

input string InpSection2_Sessions       = "=== Session Settings ===";
input int    InpLondonStartHour         = 7;
input int    InpLondonEndHour           = 16;
input int    InpNYStartHour             = 13;
input int    InpNYEndHour               = 22;
input bool   InpDisableAsian            = true;

input string InpSection3_News           = "=== News Filter Settings ===";
input bool   InpEnableNewsFilter        = true;
input int    InpMinutesBeforeRed        = 15;
input int    InpMinutesAfterRed         = 10;

input string InpSection4_Burst          = "=== Volatility Burst Settings ===";
input double InpBurstRangeMultiplier    = 1.8;
input double InpBurstVolumeMultiplier   = 1.5;
input double InpBurstBodyRatioMin       = 0.7;

input string InpSection5_Compression    = "=== Compression Settings ===";
input int    InpCompressionAtrPeriod    = 14;
input double InpCompressionAtrFactor    = 0.7;
input int    InpCompressionWindowBars   = 10;

input string InpSection6_Liquidity      = "=== Liquidity Zone & Sweep Settings ===";
input double InpEqualHLTolerancePoints  = 50;
input int    InpSwingLookbackBars       = 5;
input int    InpAsianSessionStartHour   = 0;
input int    InpAsianSessionEndHour     = 6;
input double InpSweepWickBodyRatioMin   = 2.0;
input double InpSweepVolumeSpikeMult    = 1.5;

input string InpSection7_Exhaustion     = "=== Exhaustion & Divergence Settings ===";
input double InpExhaustionMinScore      = 1.0;
input int    InpExhaustionRangeLookback = 10;
input int    InpExhaustionVolumeLookback= 20;
input int    InpRsiPeriod               = 14;
input int    InpPriceSwingLookback      = 5;
input int    InpRsiSwingLookback        = 5;
input bool   InpUseDivergenceFilter     = true;

input string InpSection8_Engines        = "=== Engine Thresholds & Timeouts ===";
input int    InpContImpulseBars         = 5;
input int    InpContPullbackBars        = 3;
input int    InpContTimeStopMinutes     = 45;
input int    InpRevTimeStopMinutes      = 60;
input double InpContTp1Partial          = 0.35;
input double InpRevTp1Partial           = 0.55;

input string InpSection9_Execution      = "=== Execution Settings ===";
input ENUM_TIMEFRAMES InpExecTimeframe  = PERIOD_M1; // M1 or M3
input ulong           InpMagicNumber    = 66008811;

//+------------------------------------------------------------------+
//| GLOBAL CONFIG INSTANCES                                          |
//+------------------------------------------------------------------+

SRiskConfig         g_riskCfg;
SSessionConfig      g_sessionCfg;
SNewsConfig         g_newsCfg;
SBurstConfig        g_burstCfg;
SCompressionConfig  g_compressionCfg;
SLiquidityZoneConfig g_liqZoneCfg;
SSweepConfig        g_sweepCfg;
SExhaustionConfig   g_exhaustionCfg;
SDivergenceConfig   g_divCfg;
SEngineThresholds   g_engineThresholds;

//--- trade object
CTrade              g_trade;

//+------------------------------------------------------------------+
//| Helper to initialize configurations from inputs                  |
//+------------------------------------------------------------------+
void InitConfigs()
  {
   // risk
   g_riskCfg.riskPerTradePct     = InpRiskPerTradePct;
   g_riskCfg.maxDailyLossPct     = InpMaxDailyLossPct;
   g_riskCfg.maxConcurrentTrades = InpMaxConcurrentTrades;
   g_riskCfg.reversalRiskFactor  = InpReversalRiskFactor;

   // sessions
   g_sessionCfg.londonStartHour  = InpLondonStartHour;
   g_sessionCfg.londonEndHour    = InpLondonEndHour;
   g_sessionCfg.nyStartHour      = InpNYStartHour;
   g_sessionCfg.nyEndHour        = InpNYEndHour;
   g_sessionCfg.disableAsian     = InpDisableAsian;

   // news
   g_newsCfg.enableNewsFilter    = InpEnableNewsFilter;
   g_newsCfg.minutesBeforeRed    = InpMinutesBeforeRed;
   g_newsCfg.minutesAfterRed     = InpMinutesAfterRed;

   // burst
   g_burstCfg.rangeMultiplier    = InpBurstRangeMultiplier;
   g_burstCfg.volumeMultiplier   = InpBurstVolumeMultiplier;
   g_burstCfg.bodyRatioMin       = InpBurstBodyRatioMin;
   g_burstCfg.lookback           = 20;

   // compression
   g_compressionCfg.atrPeriod        = InpCompressionAtrPeriod;
   g_compressionCfg.atrCompressionFactor = InpCompressionAtrFactor;
   g_compressionCfg.windowBars       = InpCompressionWindowBars;

   // liquidity zone
   g_liqZoneCfg.equalHighLowTolerancePoints = InpEqualHLTolerancePoints;
   g_liqZoneCfg.swingLookbackBars           = InpSwingLookbackBars;
   g_liqZoneCfg.asianSessionStartHour       = InpAsianSessionStartHour;
   g_liqZoneCfg.asianSessionEndHour         = InpAsianSessionEndHour;

   // sweep
   g_sweepCfg.wickBodyRatioMin       = InpSweepWickBodyRatioMin;
   g_sweepCfg.volumeSpikeMultiplier  = InpSweepVolumeSpikeMult;
   g_sweepCfg.volumeLookback         = 20;
   g_sweepCfg.structureTf            = PERIOD_M15;

   // exhaustion
   g_exhaustionCfg.minScore          = InpExhaustionMinScore;
   g_exhaustionCfg.rangeLookback     = InpExhaustionRangeLookback;
   g_exhaustionCfg.volumeLookback    = InpExhaustionVolumeLookback;

   // divergence
   g_divCfg.rsiPeriod           = InpRsiPeriod;
   g_divCfg.priceSwingLookback  = InpPriceSwingLookback;
   g_divCfg.rsiSwingLookback    = InpRsiSwingLookback;
   g_divCfg.useDivergence       = InpUseDivergenceFilter;

   // engine thresholds
   g_engineThresholds.contImpulseBars     = InpContImpulseBars;
   g_engineThresholds.contPullbackBars    = InpContPullbackBars;
   g_engineThresholds.contTimeStopMinutes = InpContTimeStopMinutes;
   g_engineThresholds.revTimeStopMinutes  = InpRevTimeStopMinutes;
   g_engineThresholds.tp1PartialCont      = InpContTp1Partial;
   g_engineThresholds.tp1PartialRev       = InpRevTp1Partial;
  }

//+------------------------------------------------------------------+
//| INDICATOR & DATA MODULES (PURE CALCULATION)                      |
//+------------------------------------------------------------------+

//--- VWAP module (intraday, execution timeframe)
class CVWAPModule
  {
private:
   string          m_symbol;
   ENUM_TIMEFRAMES m_tf;
   int             m_dayStartHour;

public:
                     CVWAPModule() : m_symbol(_Symbol), m_tf(InpExecTimeframe), m_dayStartHour(0) {}

   void              Init(const string symbol, ENUM_TIMEFRAMES tf,int day_start_hour)
     {
      m_symbol=symbol;
      m_tf=tf;
      m_dayStartHour=day_start_hour;
     }

   // daily VWAP approximation using intraday bars
   double            GetVWAP(const int shift) const
     {
      datetime time_array[];
      if(CopyTime(m_symbol,m_tf,0,shift+1,time_array)<=shift)
         return(0.0);
      datetime day_start=DateOfDay(time_array[shift]);
      datetime from=day_start;
      datetime to=TimeCurrent();

      datetime tbuf[];
      double high[],low[],close[];
      long   tickvol[];
      int copied=CopyTime(m_symbol,m_tf,from,to,tbuf);
      if(copied<=0)
         return(0.0);
      ArrayResize(high,copied);
      ArrayResize(low,copied);
      ArrayResize(close,copied);
      ArrayResize(tickvol,copied);
      CopyHigh(m_symbol,m_tf,0,copied,high);
      CopyLow(m_symbol,m_tf,0,copied,low);
      CopyClose(m_symbol,m_tf,0,copied,close);
      CopyTickVolume(m_symbol,m_tf,0,copied,tickvol);

      double pv_sum=0.0;
      double vol_sum=0.0;
      for(int i=0;i<copied;i++)
        {
         if(DateOfDay(tbuf[i])!=day_start)
            continue;
         double typical=(high[i]+low[i]+close[i])/3.0;
         double v=(double)tickvol[i];
         pv_sum+=typical*v;
         vol_sum+=v;
        }
      if(vol_sum<=0.0)
         return(0.0);
      return(pv_sum/vol_sum);
     }

   double            GetSlope(const int bars) const
     {
      if(bars<=1)
         return(0.0);
      double v_old=GetVWAP(bars-1);
      double v_new=GetVWAP(0);
      return(v_new-v_old);
     }

   bool              IsFlat(const double slope_threshold) const
     {
      return(MathAbs(GetSlope(5))<slope_threshold);
     }
  };

//--- VWMA module (execution timeframe)
class CVWMAModule
  {
private:
   string          m_symbol;
   ENUM_TIMEFRAMES m_tf;
   int             m_period;

public:
                     CVWMAModule() : m_symbol(_Symbol), m_tf(InpExecTimeframe), m_period(20) {}

   void              Init(const string symbol,ENUM_TIMEFRAMES tf,const int period)
     {
      m_symbol=symbol;
      m_tf=tf;
      m_period=period;
     }

   double            GetVWMA(const int shift) const
     {
      int needed=m_period+shift;
      double close[];
      long   tickvol[];
      int copied=CopyClose(m_symbol,m_tf,shift,needed,close);
      if(copied<m_period)
         return(0.0);
      CopyTickVolume(m_symbol,m_tf,shift,needed,tickvol);
      double pv_sum=0.0;
      double vol_sum=0.0;
      for(int i=0;i<m_period;i++)
        {
         // cast tick volume explicitly to avoid any long->double warnings
         double v=(double)tickvol[i];
         pv_sum+=close[i]*v;
         vol_sum+=v;
        }
      if(vol_sum<=0.0)
         return(0.0);
      return(pv_sum/vol_sum);
     }

   int               GetDirection() const
     {
      double v0=GetVWMA(0);
      double v1=GetVWMA(1);
      if(v0>v1)
         return(1);
      if(v0<v1)
         return(-1);
      return(0);
     }
  };

//--- Compression detector on structure TF (M15)
class CCompressionDetector
  {
private:
   string             m_symbol;
   ENUM_TIMEFRAMES    m_tf;
   SCompressionConfig m_cfg;
   bool               m_prevCompression;

public:
                     CCompressionDetector() : m_symbol(_Symbol), m_tf(PERIOD_M15), m_prevCompression(false) {}

   void              Init(const string symbol,ENUM_TIMEFRAMES tf,const SCompressionConfig &cfg)
     {
      m_symbol=symbol;
      m_tf=tf;
      m_cfg=cfg;
      m_prevCompression=false;
     }

   bool              IsCompression()
     {
      int bars_needed=MathMax(m_cfg.atrPeriod,m_cfg.windowBars)+5;
      double high[],low[],close[];
      if(CopyHigh(m_symbol,m_tf,0,bars_needed,high)<bars_needed)
         return(false);
      CopyLow(m_symbol,m_tf,0,bars_needed,low);
      CopyClose(m_symbol,m_tf,0,bars_needed,close);

      double tr_sum=0.0;
      for(int i=1;i<=m_cfg.atrPeriod;i++)
        {
         double tr=MathMax(high[i-1],close[i])-MathMin(low[i-1],close[i]);
         tr_sum+=tr;
        }
      double atr=tr_sum/m_cfg.atrPeriod;

      double tr_win_sum=0.0;
      for(int i=1;i<=m_cfg.windowBars;i++)
        {
         double tr=MathMax(high[i-1],close[i])-MathMin(low[i-1],close[i]);
         tr_win_sum+=tr;
        }
      double atr_avg=tr_win_sum/m_cfg.windowBars;
      if(atr_avg<=0.0)
         return(false);
      return(atr<atr_avg*m_cfg.atrCompressionFactor);
     }

   bool              JustExitedCompression()
     {
      bool current=IsCompression();
      bool justExited=(m_prevCompression && !current);
      m_prevCompression=current;
      return(justExited);
     }
  };

//--- Volatility burst engine (feature only)
class CVolatilityBurstEngine
  {
private:
   string          m_symbol;
   ENUM_TIMEFRAMES m_tf;
   SBurstConfig    m_cfg;
   double          m_lastRange;
   double          m_lastBodyRatio;

public:
                     CVolatilityBurstEngine() : m_symbol(_Symbol), m_tf(InpExecTimeframe), m_lastRange(0.0), m_lastBodyRatio(0.0) {}

   void              Init(const string symbol,ENUM_TIMEFRAMES tf,const SBurstConfig &cfg)
     {
      m_symbol=symbol;
      m_tf=tf;
      m_cfg=cfg;
     }

   bool              IsBurst()
     {
      int needed=m_cfg.lookback+1;
      double high[],low[],open[],close[];
      long   tickvol[];
      if(CopyHigh(m_symbol,m_tf,0,needed,high)<needed)
         return(false);
      CopyLow(m_symbol,m_tf,0,needed,low);
      CopyOpen(m_symbol,m_tf,0,needed,open);
      CopyClose(m_symbol,m_tf,0,needed,close);
      CopyTickVolume(m_symbol,m_tf,0,needed,tickvol);

      double range_cur=high[0]-low[0];
      double body_cur=MathAbs(close[0]-open[0]);
      m_lastRange=range_cur;
      m_lastBodyRatio=(range_cur>0.0 ? body_cur/range_cur : 0.0);

      double range_sum=0.0;
      double vol_sum=0.0;
      for(int i=1;i<=m_cfg.lookback;i++)
        {
         range_sum+=(high[i]-low[i]);
         vol_sum+=(double)tickvol[i];
        }
      double range_sma=range_sum/m_cfg.lookback;
      double vol_sma=vol_sum/m_cfg.lookback;

      bool condRange   =(range_cur>range_sma*m_cfg.rangeMultiplier);
      bool condVolume  =(tickvol[0]>vol_sma*m_cfg.volumeMultiplier);
      bool condBody    =(m_lastBodyRatio>=m_cfg.bodyRatioMin);

      return(condRange && condVolume && condBody);
     }

   double            LastRange() const { return(m_lastRange); }
   double            LastBodyRatio() const { return(m_lastBodyRatio); }
  };

//--- Simple liquidity zone container
struct SLiquidityZone
  {
   ELiquidityZoneType type;
   double             price;
   datetime           time;
  };

//--- Liquidity zone detector (structure TF = M15)
class CLiquidityZoneDetector
  {
private:
   string              m_symbol;
   ENUM_TIMEFRAMES     m_tf;
   SLiquidityZoneConfig m_cfg;
   SLiquidityZone      m_zones[64];
   int                 m_zoneCount;

public:
                     CLiquidityZoneDetector() : m_symbol(_Symbol), m_tf(PERIOD_M15), m_zoneCount(0) {}

   void              Init(const string symbol,ENUM_TIMEFRAMES tf,const SLiquidityZoneConfig &cfg)
     {
      m_symbol=symbol;
      m_tf=tf;
      m_cfg=cfg;
      m_zoneCount=0;
     }

   void              Rebuild()
     {
      m_zoneCount=0;
      datetime time[];
      double high[],low[];
      int bars=CopyHigh(m_symbol,m_tf,0,500,high);
      if(bars<=0)
         return;
      CopyLow(m_symbol,m_tf,0,bars,low);
      CopyTime(m_symbol,m_tf,0,bars,time);

      for(int i=m_cfg.swingLookbackBars;i<bars-m_cfg.swingLookbackBars && m_zoneCount<64;i++)
        {
         bool isHigh=true;
         bool isLow=true;
         for(int k=1;k<=m_cfg.swingLookbackBars;k++)
           {
            if(high[i]<=high[i-k] || high[i]<=high[i+k]) isHigh=false;
            if(low[i]>=low[i-k]  || low[i]>=low[i+k])  isLow=false;
           }
         if(isHigh)
           {
            m_zones[m_zoneCount].type=LQT_SWING_HIGH;
            m_zones[m_zoneCount].price=high[i];
            m_zones[m_zoneCount].time=time[i];
            m_zoneCount++;
           }
         if(isLow && m_zoneCount<64)
           {
            m_zones[m_zoneCount].type=LQT_SWING_LOW;
            m_zones[m_zoneCount].price=low[i];
            m_zones[m_zoneCount].time=time[i];
            m_zoneCount++;
           }
        }

      datetime today=DateOfDay(TimeCurrent());
      double sessHigh=0.0,sessLow=0.0;
      bool haveSess=false;
      for(int i=0;i<bars;i++)
        {
         if(DateOfDay(time[i])==today) continue;
         if(!haveSess)
           {
            sessHigh=high[i];
            sessLow=low[i];
            haveSess=true;
           }
         else
           {
            sessHigh=MathMax(sessHigh,high[i]);
            sessLow =MathMin(sessLow, low[i]);
           }
        }
      if(haveSess && m_zoneCount+2<=64)
        {
         m_zones[m_zoneCount].type=LQT_SESSION_HIGH;
         m_zones[m_zoneCount].price=sessHigh;
         m_zones[m_zoneCount].time=today-86400;
         m_zoneCount++;

         m_zones[m_zoneCount].type=LQT_SESSION_LOW;
         m_zones[m_zoneCount].price=sessLow;
         m_zones[m_zoneCount].time=today-86400;
         m_zoneCount++;
        }
     }

   int               GetNearestZoneIndex(const double price,const int direction) const
     {
      int best=-1;
      double bestDist=DBL_MAX;
      for(int i=0;i<m_zoneCount;i++)
        {
         if(direction>0 && m_zones[i].price<=price) continue;
         if(direction<0 && m_zones[i].price>=price) continue;
         double dist=MathAbs(m_zones[i].price-price);
         if(dist<bestDist)
           {
            bestDist=dist;
            best=i;
           }
        }
      return(best);
     }

   int               ZoneCount() const { return(m_zoneCount); }
   double            GetZonePrice(const int index) const { return((index>=0 && index<m_zoneCount)?m_zones[index].price:0.0); }
   ELiquidityZoneType GetZoneType(const int index) const { return((index>=0 && index<m_zoneCount)?m_zones[index].type:LQT_NONE); }
  };

//--- Liquidity sweep detector (takes zone detector by reference to avoid pointer member access)
class CLiquiditySweepDetector
  {
private:
   string              m_symbol;
   ENUM_TIMEFRAMES     m_tf;
   SSweepConfig        m_cfg;

public:
                     CLiquiditySweepDetector() : m_symbol(_Symbol), m_tf(PERIOD_M15) {}

   void              Init(const string symbol,ENUM_TIMEFRAMES tf,const SSweepConfig &cfg)
     {
      m_symbol=symbol;
      m_tf=tf;
      m_cfg=cfg;
     }

   bool              IsSweep(CLiquidityZoneDetector &zoneDet,int &direction,int &zoneIndex)
     {
      direction=SIDE_NONE;
      zoneIndex=-1;

      double high[],low[],open[],close[];
      long   tickvol[];
      if(CopyHigh(m_symbol,m_tf,0,3,high)<3)
         return(false);
      CopyLow(m_symbol,m_tf,0,3,low);
      CopyOpen(m_symbol,m_tf,0,3,open);
      CopyClose(m_symbol,m_tf,0,3,close);
      CopyTickVolume(m_symbol,m_tf,0,3,tickvol);

      double lastHigh=high[0];
      double lastLow =low[0];
      double lastOpen=open[0];
      double lastClose=close[0];

      double body=MathAbs(lastClose-lastOpen);
      double upperWick=(lastHigh-MathMax(lastOpen,lastClose));
      double lowerWick=(MathMin(lastOpen,lastClose)-lastLow);

      double vol_sum=0.0;
      for(int i=1;i<=m_cfg.volumeLookback && i<ArraySize(tickvol);i++)
         vol_sum+=(double)tickvol[i];
      double vol_sma=m_cfg.volumeLookback>0 ? vol_sum/MathMin(m_cfg.volumeLookback,ArraySize(tickvol)-1) : 0.0;
      bool volSpike=(vol_sma>0 && tickvol[0]>vol_sma*m_cfg.volumeSpikeMultiplier);

      double price=lastClose;
      int dirCandidate=SIDE_NONE;
      int zIndex=-1;

      int idxAbove=zoneDet.GetNearestZoneIndex(price,1);
      if(idxAbove>=0)
        {
         double zPrice=zoneDet.GetZonePrice(idxAbove);
         if(lastHigh>zPrice && lastClose<zPrice)
           {
            double ratio=(body>0.0 ? upperWick/body : 0.0);
            if(ratio>=m_cfg.wickBodyRatioMin && volSpike)
              {
               dirCandidate=SIDE_SELL;
               zIndex=idxAbove;
              }
           }
        }

      int idxBelow=zoneDet.GetNearestZoneIndex(price,-1);
      if(idxBelow>=0 && dirCandidate==SIDE_NONE)
        {
         double zPrice=zoneDet.GetZonePrice(idxBelow);
         if(lastLow<zPrice && lastClose>zPrice)
           {
            double ratio=(body>0.0 ? lowerWick/body : 0.0);
            if(ratio>=m_cfg.wickBodyRatioMin && volSpike)
              {
               dirCandidate=SIDE_BUY;
               zIndex=idxBelow;
              }
           }
        }

      if(dirCandidate!=SIDE_NONE)
        {
         direction=dirCandidate;
         zoneIndex=zIndex;
         return(true);
        }
      return(false);
     }
  };

//--- Exhaustion math module (takes VWAP by reference to avoid pointer member access)
class CExhaustionMathModule
  {
private:
   string            m_symbol;
   ENUM_TIMEFRAMES   m_tf;
   SExhaustionConfig m_cfg;

public:
                     CExhaustionMathModule() : m_symbol(_Symbol), m_tf(InpExecTimeframe) {}

   void              Init(const string symbol,ENUM_TIMEFRAMES tf,const SExhaustionConfig &cfg)
     {
      m_symbol=symbol;
      m_tf=tf;
      m_cfg=cfg;
     }

   double            ComputeScore(const int direction,CVWAPModule &vwapMod)
     {
      double close[];
      int copied=CopyClose(m_symbol,m_tf,0,m_cfg.rangeLookback+1,close);
      if(copied<m_cfg.rangeLookback+1)
         return(0.0);

      double maxP=close[0],minP=close[0];
      for(int i=1;i<=m_cfg.rangeLookback;i++)
        {
         if(close[i]>maxP) maxP=close[i];
         if(close[i]<minP) minP=close[i];
        }
      double range=maxP-minP;

      double vwap=vwapMod.GetVWAP(0);
      double dist=MathAbs(close[0]-vwap);

      long   tickvol[];
      int vCopied=CopyTickVolume(m_symbol,m_tf,0,m_cfg.volumeLookback+1,tickvol);
      double vol_sum=0.0;
      for(int i=1;i<=m_cfg.volumeLookback && i<vCopied;i++)
         vol_sum+=(double)tickvol[i];
      double vol_sma=m_cfg.volumeLookback>0 ? vol_sum/MathMin(m_cfg.volumeLookback,vCopied-1) : 0.0;
      double vol_score=(vol_sma>0 ? (double)tickvol[0]/vol_sma : 0.0);

      double score=(range>0.0 ? dist/range : 0.0)+vol_score;
      return(score);
     }

   bool              IsExhausted(const int direction,CVWAPModule &vwapMod)
     {
      double s=ComputeScore(direction,vwapMod);
      return(s>=m_cfg.minScore);
     }
  };

//--- Divergence module (simple RSI divergence on execution TF)
class CDivergenceModule
  {
private:
   string            m_symbol;
   ENUM_TIMEFRAMES   m_tf;
   SDivergenceConfig m_cfg;
   int               m_rsiHandle;

public:
                     CDivergenceModule() : m_symbol(_Symbol), m_tf(InpExecTimeframe), m_rsiHandle(INVALID_HANDLE) {}

   void              Init(const string symbol,ENUM_TIMEFRAMES tf,const SDivergenceConfig &cfg)
     {
      m_symbol=symbol;
      m_tf=tf;
      m_cfg=cfg;
      if(m_rsiHandle!=INVALID_HANDLE)
         IndicatorRelease(m_rsiHandle);
      m_rsiHandle=iRSI(m_symbol,m_tf,m_cfg.rsiPeriod,PRICE_CLOSE);
     }

   void              Release()
     {
      if(m_rsiHandle!=INVALID_HANDLE)
        {
         IndicatorRelease(m_rsiHandle);
         m_rsiHandle=INVALID_HANDLE;
        }
     }

   bool              HasBullishDivergence()
     {
      if(!m_cfg.useDivergence || m_rsiHandle==INVALID_HANDLE)
         return(false);
      double close[],rsi[];
      int needed=m_cfg.priceSwingLookback+m_cfg.rsiSwingLookback+5;
      if(CopyClose(m_symbol,m_tf,0,needed,close)<needed)
         return(false);
      if(CopyBuffer(m_rsiHandle,0,0,needed,rsi)<needed)
         return(false);

      int i1=m_cfg.priceSwingLookback;
      int i2=m_cfg.priceSwingLookback+m_cfg.rsiSwingLookback;

      double price1=close[i1];
      double price2=close[i2];
      double rsi1=rsi[i1];
      double rsi2=rsi[i2];

      if(price1>price2 && rsi1<rsi2)
         return(true);
      return(false);
     }

   bool              HasBearishDivergence()
     {
      if(!m_cfg.useDivergence || m_rsiHandle==INVALID_HANDLE)
         return(false);
      double close[],rsi[];
      int needed=m_cfg.priceSwingLookback+m_cfg.rsiSwingLookback+5;
      if(CopyClose(m_symbol,m_tf,0,needed,close)<needed)
         return(false);
      if(CopyBuffer(m_rsiHandle,0,0,needed,rsi)<needed)
         return(false);

      int i1=m_cfg.priceSwingLookback;
      int i2=m_cfg.priceSwingLookback+m_cfg.rsiSwingLookback;

      double price1=close[i1];
      double price2=close[i2];
      double rsi1=rsi[i1];
      double rsi2=rsi[i2];

      if(price1<price2 && rsi1>rsi2)
         return(true);
      return(false);
     }
  };

//+------------------------------------------------------------------+
//| FILTERS & RISK MODULES                                           |
//+------------------------------------------------------------------+

//--- Session filter (London + NY, optional Asian disable)
class CSessionFilter
  {
private:
   SSessionConfig m_cfg;

public:
   void Init(const SSessionConfig &cfg)
     {
      m_cfg = cfg;
     }

   bool IsSessionAllowed() const
     {
      MqlDateTime tm;
      TimeToStruct(TimeCurrent(), tm);
      int hour = tm.hour;

      bool inLondon = (hour >= m_cfg.londonStartHour && hour < m_cfg.londonEndHour);
      bool inNY     = (hour >= m_cfg.nyStartHour     && hour < m_cfg.nyEndHour);

      // Only allow London or NY sessions; Asian is implicitly excluded
      return (inLondon || inNY);
     }
  };

//--- News filter (stub: structure + time-window logic, without direct calendar API)
class CNewsFilter
  {
private:
   SNewsConfig m_cfg;
   datetime    m_lastRefresh;

public:
   void Init(const SNewsConfig &cfg)
     {
      m_cfg=cfg;
      m_lastRefresh=0;
     }

   void RefreshIfNeeded()
     {
      // Placeholder for future integration with broker economic calendar.
      m_lastRefresh=TimeCurrent();
     }

   bool IsBlockedNow()
     {
      if(!m_cfg.enableNewsFilter)
         return(false);

      // NOTE:
      // This stub currently does not enforce a real news blackout because
      // economic calendar availability can differ between brokers and terminals.
      // Trading is never blocked here; integrate broker-specific news logic
      // inside this method if your environment supports it.
      return(false);
     }
  };

//--- Risk engine for sizing and daily lockout
class CRiskEngine
  {
private:
   SRiskConfig m_cfg;
   double      m_dailyStartEquity;
   double      m_dailyRealizedPnl;
   datetime    m_dailyDate;

public:
   void Init(const SRiskConfig &cfg)
     {
      m_cfg=cfg;
      m_dailyStartEquity=AccountInfoDouble(ACCOUNT_EQUITY);
      m_dailyRealizedPnl=0.0;
      m_dailyDate=DateOfDay(TimeCurrent());
     }

   void UpdateDay()
     {
      datetime today=DateOfDay(TimeCurrent());
      if(today!=m_dailyDate)
        {
         m_dailyDate=today;
         m_dailyStartEquity=AccountInfoDouble(ACCOUNT_EQUITY);
         m_dailyRealizedPnl=0.0;
        }
     }

   void RegisterTradeClose(double pnl)
     {
      m_dailyRealizedPnl+=pnl;
     }

   bool IsDailyLockedOut() const
     {
      double ddPct=(m_dailyStartEquity>0.0 ? -m_dailyRealizedPnl*100.0/m_dailyStartEquity : 0.0);
      return(ddPct>=m_cfg.maxDailyLossPct-1e-6);
     }

   int ActiveTradesCount(ulong magic,const string symbol) const
     {
      int total=PositionsTotal();
      int count=0;
      for(int i=0;i<total;i++)
        {
         ulong ticket=PositionGetTicket(i);
         if(!PositionSelectByTicket(ticket))
            continue;
         if((ulong)PositionGetInteger(POSITION_MAGIC)!=magic)
            continue;
         if((string)PositionGetString(POSITION_SYMBOL)!=symbol)
            continue;
         count++;
        }
      return(count);
     }

   bool CanOpenNewTrade(double stopPoints,bool isReversal,double &lotsOut,ulong magic,const string symbol)
     {
      UpdateDay();

      lotsOut=0.0;
      if(IsDailyLockedOut())
         return(false);

      if(ActiveTradesCount(magic,symbol)>=m_cfg.maxConcurrentTrades)
         return(false);

      double equity=AccountInfoDouble(ACCOUNT_EQUITY);
      double riskPct=m_cfg.riskPerTradePct;
      if(isReversal)
         riskPct*=m_cfg.reversalRiskFactor;

      double riskAmount=equity*riskPct/100.0;
      if(riskAmount<=0.0 || stopPoints<=0.0)
         return(false);

      double tickValue=SymbolInfoDouble(symbol,SYMBOL_TRADE_TICK_VALUE);
      double tickSize =SymbolInfoDouble(symbol,SYMBOL_TRADE_TICK_SIZE);
      double contractSize=SymbolInfoDouble(symbol,SYMBOL_TRADE_CONTRACT_SIZE);

      double stopPriceDist=stopPoints*SymbolInfoDouble(symbol,SYMBOL_POINT);
      double lossPerLot=(stopPriceDist/tickSize)*tickValue;
      if(lossPerLot<=0.0)
         return(false);

      double lots=riskAmount/lossPerLot;
      double minLot=SymbolInfoDouble(symbol,SYMBOL_VOLUME_MIN);
      double maxLot=SymbolInfoDouble(symbol,SYMBOL_VOLUME_MAX);
      double stepLot=SymbolInfoDouble(symbol,SYMBOL_VOLUME_STEP);

      lots=MathFloor(lots/stepLot)*stepLot;
      if(lots<minLot)
         return(false);
      if(lots>maxLot)
         lots=maxLot;

      lotsOut=lots;
      return(true);
     }
  };

//--- module instances (after class definitions)
CVWAPModule             g_vwap;
CVWMAModule             g_vwma;
CCompressionDetector    g_compression;
CVolatilityBurstEngine g_burst;
CLiquidityZoneDetector  g_liqZones;
CLiquiditySweepDetector g_sweep;
CExhaustionMathModule   g_exhaustion;
CDivergenceModule       g_divergence;
CSessionFilter          g_sessionFilter;
CNewsFilter             g_newsFilter;
CRiskEngine             g_riskEngine;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    // Initialize configs
    InitConfigs();

    // Trade execution settings
    g_trade.SetDeviationInPoints(10);
    g_trade.SetTypeFilling(ORDER_FILLING_IOC);

    // Initialize modules
    g_vwap.Init(_Symbol, InpExecTimeframe, 0);
    g_vwma.Init(_Symbol, InpExecTimeframe, 20);
    g_compression.Init(_Symbol, PERIOD_M15, g_compressionCfg);
    g_burst.Init(_Symbol, InpExecTimeframe, g_burstCfg);
    g_liqZones.Init(_Symbol, PERIOD_M15, g_liqZoneCfg);
    g_sweep.Init(_Symbol, PERIOD_M15, g_sweepCfg);
    g_exhaustion.Init(_Symbol, InpExecTimeframe, g_exhaustionCfg);
    g_divergence.Init(_Symbol, InpExecTimeframe, g_divCfg);
    g_sessionFilter.Init(g_sessionCfg);
    g_newsFilter.Init(g_newsCfg);
    g_riskEngine.Init(g_riskCfg);

    return(INIT_SUCCEEDED);
}


//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   g_divergence.Release();
  }

//+------------------------------------------------------------------+
//| Run main execution: filters, sweep/continuation, risk, execute   |
//+------------------------------------------------------------------+
void RunMainExecution()
  {
   if(!g_sessionFilter.IsSessionAllowed())
      return;
   if(g_newsFilter.IsBlockedNow())
      return;
   g_riskEngine.UpdateDay();
   if(g_riskEngine.IsDailyLockedOut())
      return;
   if(g_riskEngine.ActiveTradesCount(InpMagicNumber,_Symbol)>=g_riskCfg.maxConcurrentTrades)
      return;

   g_liqZones.Rebuild();
   int sweepDir=SIDE_NONE;
   int zoneIdx=-1;
   bool hasSweep=g_sweep.IsSweep(g_liqZones,sweepDir,zoneIdx);

   double point=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   if(point<=0.0)
      return;
   const double slBufferPoints=20.0;
   const double riskRewardRatio=1.5;

   if(hasSweep && sweepDir!=SIDE_NONE)
     {
      bool exhaustionOk=g_exhaustion.IsExhausted(sweepDir,g_vwap);
      bool divOk=true;
      if(g_divCfg.useDivergence)
         divOk=(sweepDir==SIDE_BUY && g_divergence.HasBullishDivergence()) ||
               (sweepDir==SIDE_SELL && g_divergence.HasBearishDivergence());
      if(!exhaustionOk || !divOk)
         return;

      double zonePrice=g_liqZones.GetZonePrice(zoneIdx);
      double entry=(sweepDir==SIDE_BUY)?SymbolInfoDouble(_Symbol,SYMBOL_ASK):SymbolInfoDouble(_Symbol,SYMBOL_BID);
      double slPrice=(sweepDir==SIDE_BUY)?zonePrice-slBufferPoints*point:zonePrice+slBufferPoints*point;
      double slDist=MathAbs(entry-slPrice);
      int stopPoints=(int)MathRound(slDist/point);
      if(stopPoints<=0)
         return;

      double lots=0.0;
      if(!g_riskEngine.CanOpenNewTrade(stopPoints,true,lots,InpMagicNumber,_Symbol))
         return;

      double tpDist=slDist*riskRewardRatio;
      double tpPrice=(sweepDir==SIDE_BUY)?entry+tpDist:entry-tpDist;
      if(sweepDir==SIDE_BUY)
         g_trade.Buy(lots,_Symbol,0,slPrice,tpPrice,"Rev");
      else
         g_trade.Sell(lots,_Symbol,0,slPrice,tpPrice,"Rev");
      return;
     }

   bool isBurst=g_burst.IsBurst();
   if(!isBurst)
      return;
   double vwapSlope=g_vwap.GetSlope(5);
   const double slopeThreshold=0.15;
   if(MathAbs(vwapSlope)<slopeThreshold)
      return;
   bool compressionExited=g_compression.JustExitedCompression();
   int vwmaDir=g_vwma.GetDirection();
   int direction=(vwmaDir==1)?SIDE_BUY:SIDE_SELL;
   if(vwmaDir==0)
      direction=(vwapSlope>0.0)?SIDE_BUY:SIDE_SELL;

   double high[],low[];
   if(CopyHigh(_Symbol,InpExecTimeframe,0,g_engineThresholds.contImpulseBars+1,high)<g_engineThresholds.contImpulseBars+1)
      return;
   if(CopyLow(_Symbol,InpExecTimeframe,0,g_engineThresholds.contImpulseBars+1,low)<g_engineThresholds.contImpulseBars+1)
      return;
   double swingLow=low[0],swingHigh=high[0];
   for(int i=1;i<g_engineThresholds.contImpulseBars;i++)
     {
      if(low[i]<swingLow) swingLow=low[i];
      if(high[i]>swingHigh) swingHigh=high[i];
     }
   double entry=(direction==SIDE_BUY)?SymbolInfoDouble(_Symbol,SYMBOL_ASK):SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double slPrice=(direction==SIDE_BUY)?swingLow-point*10:swingHigh+point*10;
   double slDist=MathAbs(entry-slPrice);
   int stopPoints=(int)MathRound(slDist/point);
   if(stopPoints<=0)
      return;

   double lots=0.0;
   if(!g_riskEngine.CanOpenNewTrade(stopPoints,false,lots,InpMagicNumber,_Symbol))
      return;

   double tpDist=slDist*riskRewardRatio;
   double tpPrice=(direction==SIDE_BUY)?entry+tpDist:entry-tpDist;
   if(direction==SIDE_BUY)
      g_trade.Buy(lots,_Symbol,0,slPrice,tpPrice,"Cont");
   else
      g_trade.Sell(lots,_Symbol,0,slPrice,tpPrice,"Cont");
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   static datetime s_lastBarTime=0;
   datetime barTime=iTime(_Symbol,InpExecTimeframe,0);
   if(barTime==s_lastBarTime)
      return;
   s_lastBarTime=barTime;
   RunMainExecution();
  }
//+------------------------------------------------------------------+