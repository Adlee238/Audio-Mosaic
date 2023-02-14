//------------------------------------------------------------------------------
// name: mosaic-synth-osc-kb.ck (v1.2)
// desc: basic structure for a feature-based synthesizer
//       this particular version uses microphone as live input,
//       send OSC message to whoever listening (e.g., visuals)
//       and responds to keyboard input (1-9, f, d, c)
//
// version: need chuck version 1.4.2.1 or higher
// sorting: part of ChAI (ChucK for AI)
//
// USAGE: run with INPUT model file
//        > chuck mosaic-synth-osc-kb:file
//
// uncomment the next line to learn more about the KNN2 object:
// KNN2.help();
//
// date: Spring 2023
// authors: Ge Wang (https://ccrma.stanford.edu/~ge/)
//          Yikai Li
//          Andrew Lee
//------------------------------------------------------------------------------


// which keyboard to open
0 => int KB_DEVICE;

// input: pre-extracted model file
"data/great-show.txt" => string GS_FILE;
"data/never-enough.txt" => string NE_FILE;
"data/tightrope.txt" => string TR_FILE;

//------------------------------------------------------------------------------
// expected model file format; each VALUE is a feature value
// (feel free to adapt and modify the file format as needed)
//------------------------------------------------------------------------------
// filePath windowStartTime VALUE VALUE ... VALUE
// filePath windowStartTime VALUE VALUE ... VALUE
// ...
// filePath windowStartTime VALUE VALUE ... VALUE
//------------------------------------------------------------------------------


//------------------------------------------------------------------------------
// unit analyzer network: *** this must match the features in the features file
//------------------------------------------------------------------------------
// audio input into a FFT
adc => FFT fft;
// a thing for collecting multiple features into one vector
FeatureCollector combo => blackhole;
fft =^ Centroid centroid =^ combo;    // size 1
fft =^ Flux flux =^ combo;    // size 1
fft =^ RMS rms =^ combo;    // size 1
fft =^ RollOff rolloff =^ combo;    // size 1
fft =^ SFM sfm =^ combo;    // size 24
fft =^ MFCC mfcc =^ combo;    // size 20


//-----------------------------------------------------------------------------
// setting analysis parameters -- also should match what was used during extration
//-----------------------------------------------------------------------------
// set number of coefficients in MFCC (how many we get out)
// 13 is a commonly used value; using less here for printing
20 => mfcc.numCoeffs;
// set number of mel filters in MFCC
10 => mfcc.numFilters;

// do one .upchuck() so FeatureCollector knows how many total dimension
combo.upchuck();
// get number of total feature dimensions
combo.fvals().size() => int NUM_DIMENSIONS;

// set FFT size
4096 => fft.size;
// set window type and size
Windowing.hann(fft.size()) => fft.window;
// how many frames to aggregate before averaging?
4 => int NUM_FRAMES;
// our hop size (how often to perform analysis)
(fft.size()/2)::samp => dur HOP;
// how much time to aggregate features for each file
fft.size()::samp * NUM_FRAMES => dur EXTRACT_TIME;




//------------------------------------------------------------------------------
// unit generator network: for real-time sound synthesis
//------------------------------------------------------------------------------
// how many max at any time?
6 => int NUM_VOICES;
// a number of audio buffers to cycle between
SndBuf buffers[NUM_VOICES]; ADSR envs[NUM_VOICES]; Pan2 pans[NUM_VOICES];
// set parameters
for( int i; i < NUM_VOICES; i++ )
{
    // connect audio
    buffers[i] => envs[i] => pans[i] => dac;
    // set chunk size (how to to load at a time)
    // this is important when reading from large files
    // if this is not set, SndBuf.read() will load the entire file immediately
    fft.size() => buffers[i].chunks;
    // randomize pan
    Math.random2f(-.75,.75) => pans[i].pan;
    // set envelope parameters
    envs[i].set( EXTRACT_TIME, EXTRACT_TIME/2, 1, EXTRACT_TIME );
}


//------------------------------------------------------------------------------
// each Point corresponds to one line in the input file, which is one audio window
//------------------------------------------------------------------------------
class AudioWindow
{
    // unique point index (use this to lookup feature vector)
    int uid;
    // which file did this come file (in files arary)
    int fileIndex;
    // starting time in that file (in seconds)
    float windowTime;
    
    // set
    fun void set( int id, int fi, float wt )
    {
        id => uid;
        fi => fileIndex;
        wt => windowTime;
    }
}

// filenames and maping array
["data/great-show.wav", 
 "data/never-enough.wav", 
 "data/tightrope.wav"] @=> string files[];
int filename2state[files.size()];
for (int i; i < filename2state.size(); i++) {
    i => filename2state[files[i]];
}

// use this xfor new input
float features[NUM_FRAMES][NUM_DIMENSIONS];
// average values of coefficients across frames
float featureMean[NUM_DIMENSIONS];


//------------------------------------------------------------------------------
// load and read the data to create windows, inFeatures, and uids for each song
//------------------------------------------------------------------------------
// numPoints for each file
1091 => int numPointsGS;
742 => int numPointsNE;
847 => int numPointsTR;

// Greatest Show
loadFile( GS_FILE ) @=> FileIO @ fin;
AudioWindow windowsGS[numPointsGS];    // array of all points in GS file
float inFeaturesGS[numPointsGS][NUM_DIMENSIONS];    // feature vectors of datapoints in GS file
int uidsGS[numPointsGS]; for( int i; i < numPointsGS; i++ ) i => uidsGS[i];    // uids for GS file
readData( fin, windowsGS, inFeaturesGS);

// Never Enough
loadFile( NE_FILE ) @=> fin;
AudioWindow windowsNE[numPointsNE];    
float inFeaturesNE[numPointsNE][NUM_DIMENSIONS];    
int uidsNE[numPointsNE]; for( int i; i < numPointsNE; i++ ) i => uidsNE[i];   
readData( fin, windowsNE, inFeaturesNE);

// Tightrope
loadFile( TR_FILE ) @=> fin;
AudioWindow windowsTR[numPointsTR];    
float inFeaturesTR[numPointsTR][NUM_DIMENSIONS];    
int uidsTR[numPointsTR]; for( int i; i < numPointsTR; i++ ) i => uidsTR[i];   
readData( fin, windowsTR, inFeaturesTR);

[windowsGS, windowsNE, windowsTR] @=> AudioWindow windows[][];


//------------------------------------------------------------------------------
// set up our KNN object to use for classification
// (KNN2 is a fancier version of the KNN object)
// -- run KNN2.help(); in a separate program to see its available functions --
//------------------------------------------------------------------------------
KNN2 knnGreatShow;
KNN2 knnNeverEnough;
KNN2 knnTightrope;
// k nearest neighbors
2 => int K;
// results vector (indices of k nearest points)
int knnResult[K];

// train the knn models
knnGreatShow.train( inFeaturesGS, uidsGS );
knnNeverEnough.train( inFeaturesNE, uidsNE );
knnTightrope.train( inFeaturesTR, uidsTR );
[knnGreatShow, knnNeverEnough, knnTightrope] @=> KNN2 knns[];

// used to rotate sound buffers
0 => int which;

// key modes
0 => int SONG_MODE;
false => int MODE_PLAY;
false => int MODE_FREEZE;
1 => float SOUND_RATE;
AudioWindow @ CURR_WIN;


//------------------------------------------------------------------------------
// SYNTHESIS!!
// this function is meant to be sporked so it can be stacked in time
//------------------------------------------------------------------------------
fun void synthesize( int uid )
{
    // get the buffer to use
    buffers[which] @=> SndBuf @ sound;
    // get the envelope to use
    envs[which] @=> ADSR @ envelope;
    // increment and wrap if needed
    which++; if( which >= buffers.size() ) 0 => which;
    // get a reference to the audio fragment to synthesize
    AudioWindow win;
    windows[SONG_MODE][uid] @=> win @=> CURR_WIN;
    // get filename
    files[win.fileIndex] => string filename;
    // load into sound buffer
    filename => sound.read;
    // 
    SOUND_RATE => sound.rate;
    // seek to the window start time
    ((win.windowTime::second)/samp) $ int => sound.pos;

    // open the envelope, overlap add this into the overall audio
    envelope.keyOn();
    // wait
    (EXTRACT_TIME*2)-envelope.releaseTime() => now;
    // start the release
    envelope.keyOff();
    // wait
    envelope.releaseTime() => now;
}


// destination host name
"localhost" => string hostname;
// destination port number
12000 => int port;

// sender object
OscOut xmit;

// aim the transmitter at destination
xmit.dest( hostname, port );


Hid hid;
HidMsg msg;

// open keyboard (get device number from command line)
if( !hid.openKeyboard( KB_DEVICE ) ) me.exit();
<<< "keyboard '" + hid.name() + "' ready", "" >>>;

spork ~ kb();

fun void kb()
{
    // infinite event loop
    while( true )
    {
        // wait on event
        hid => now;
        
        // get one or more messages
        while( hid.recv( msg ) )
        {
            // check for action type
            if( msg.isButtonDown() ) // button pressed
            {
                false => int mode_changed;
                if( msg.ascii >= 49 && msg.ascii <= 51 ) // 1 - 3 : Song Mode
                {
                    msg.ascii-49 => SONG_MODE;
                    // switching songs also resets all other modes
                    false => MODE_FREEZE; 
                    false => MODE_PLAY;
                    1 => SOUND_RATE;
                    true => mode_changed;
                }
                else if ( msg.ascii == 90 ) // Z: reset Mode Freeze / Play
                {
                    false => MODE_FREEZE; 
                    false => MODE_PLAY;
                    1 => SOUND_RATE;
                    true => mode_changed;
                }
                else if( msg.ascii == 81 || msg.ascii == 87 ) // Q, W : Mode Freeze or Mode Play
                {
                    if( msg.ascii == 81 ) { // Q: Mode Freeze
                        true => MODE_FREEZE;
                        false => MODE_PLAY;
                    }
                    else if( msg.ascii == 87 ) { // W: Mode Play (play continously)
                        true => MODE_PLAY;
                        false => MODE_FREEZE;
                    }
                    true => mode_changed;
                }
                else if( msg.ascii == 65 || msg.ascii == 83 || msg.ascii == 68) // A, S, D : Sound Rate
                {
                    if( msg.ascii == 65 ) 0.5 => SOUND_RATE; 
                    else if( msg.ascii == 83 ) 1 => SOUND_RATE;
                    else if( msg.ascii == 68 ) 2 => SOUND_RATE;
                    true => mode_changed;
                }
                
                // mode changed, so print updates
                if ( mode_changed ) 
                {
                    chout <= "Song Mode [" <= files[SONG_MODE] <= "]; "
                      <= "Play Mode [" <= MODE_PLAY <= "]; "
                      <= "Freeze Mode [" <= MODE_FREEZE <= "]; "
                      <= "Sound Rate [" <= SOUND_RATE <= "]";
                      chout <= IO.newline();
                }
            }
        }
    }
}


//------------------------------------------------------------------------------
// real-time similarity retrieval loop
//------------------------------------------------------------------------------
// print initial modes
chout <= "Song Mode [" <= files[SONG_MODE] <= "]; "
      <= "Play Mode [" <= MODE_PLAY <= "]; "
      <= "Freeze Mode [" <= MODE_FREEZE <= "]; "
      <= "Sound Rate [" <= SOUND_RATE <= "]";
chout <= IO.newline();

// UID variable
0 => int uid;
// continous loop
while( true )
{
    // aggregate features over a period of time
    for( int frame; frame < NUM_FRAMES; frame++ )
    {
        //-------------------------------------------------------------
        // a single upchuck() will trigger analysis on everything
        // connected upstream from combo via the upchuck operator (=^)
        // the total number of output dimensions is the sum of
        // dimensions of all the connected unit analyzers
        //-------------------------------------------------------------
        combo.upchuck();  
        // get features
        for( int d; d < NUM_DIMENSIONS; d++) 
        {
            // store them in current frame
            combo.fval(d) => features[frame][d];
        }
        // advance time
        HOP => now;
    }
    
    // compute means for each coefficient across frames
    for( int d; d < NUM_DIMENSIONS; d++ )
    {
        // zero out
        0.0 => featureMean[d];
        // loop over frames
        for( int j; j < NUM_FRAMES; j++ )
        {
            // add
            features[j][d] +=> featureMean[d];
        }
        // average
        NUM_FRAMES /=> featureMean[d];
    }
    
    //---------------------------------------------------------
    // search using specified KNN2 model; results filled in 
    // knnResults, which should the indices of k nearest points
    //---------------------------------------------------------
    if ( MODE_PLAY ) 
    {   // play continously (unaffected by data)
        uid++;
        if (uid >= windows[SONG_MODE].size()) {
            0 => uid;
        }
    }
    else if ( MODE_FREEZE )
    {   // freeze current window
        uid => uid;
    }
    else 
    {   // play in response to audio input
        knns[SONG_MODE].search( featureMean, K, knnResult );
        knnResult[Math.random2(0,knnResult.size()-1)] => uid;
    }
    
    // SYNTHESIZE THIS
    spork ~ synthesize( uid );
}
//------------------------------------------------------------------------------
// end of real-time similiarity retrieval loop
//------------------------------------------------------------------------------




//------------------------------------------------------------------------------
// function: load data file
//------------------------------------------------------------------------------
fun FileIO loadFile( string filepath )
{
    // reset
    0 => int numPoints;
    0 => int numCoeffs;
    
    // load data
    FileIO fio;
    if( !fio.open( filepath, FileIO.READ ) )
    {
        // error
        <<< "cannot open file:", filepath >>>;
        // close
        fio.close();
        // return
        return fio;
    }
    
    string str;
    string line;
    // read the first non-empty line
    while( fio.more() )
    {
        // read each line
        fio.readLine().trim() => str;
        // check if empty line
        if( str != "" )
        {
            numPoints++;
            str => line;
        }
    }
    
    // a string tokenizer
    StringTokenizer tokenizer;
    // set to last non-empty line
    tokenizer.set( line );
    // negative (to account for filePath windowTime)
    -2 => numCoeffs;
    // see how many, including label name
    while( tokenizer.more() )
    {
        tokenizer.next();
        numCoeffs++;
    }
    
    // see if we made it past the initial fields
    if( numCoeffs < 0 ) 0 => numCoeffs;
    
    // check
    if( numPoints == 0 || numCoeffs <= 0 )
    {
        <<< "no data in file:", filepath >>>;
        fio.close();
        return fio;
    }
    
    // print
    <<< "# of data points in",  filepath,":", numPoints, "dimensions:", numCoeffs >>>;
    
    // done for now
    return fio;
}


//------------------------------------------------------------------------------
// function: read the data
//------------------------------------------------------------------------------
fun void readData( FileIO fio , AudioWindow windows[], float inFeatures[][])
{
    // rewind the file reader
    fio.seek( 0 );
    
    // a line
    string line;
    // a string tokenizer
    StringTokenizer tokenizer;
    
    // points index
    0 => int index;
    // file index
    0 => int fileIndex;
    // file name
    string filename;
    // window start time
    float windowTime;
    // coefficient
    int c;

    0 => int numPoints;
    NUM_DIMENSIONS => int numCoeffs;
    
    // read the first non-empty line
    while( fio.more() )
    {
        numPoints++;
        // read each line
        fio.readLine().trim() => line;
        // check if empty line
        if( line != "" )
        {
            // set to last non-empty line
            tokenizer.set( line );
            // file name
            tokenizer.next() => filename;
            // window start time
            tokenizer.next() => Std.atof => windowTime;
            // get fileindex
            filename2state[filename] => fileIndex;
            // set
            windows[index].set( index, fileIndex, windowTime );

            // zero out
            0 => c;
            // for each dimension in the data
            repeat( numCoeffs )
            {
                // read next coefficient
                tokenizer.next() => Std.atof => inFeatures[index][c];
                // increment
                c++;
            }
            
            // increment global index
            index++;
        }
    }
}
