%{
----------------------------------------------------------------------------

This file is part of the Sanworks Bpod repository
Copyright (C) 2022 Sanworks LLC, Rochester, New York, USA

----------------------------------------------------------------------------

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, version 3.

This program is distributed  WITHOUT ANY WARRANTY and without even the 
implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  
See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.
%}

% Usage Notes:
% Required: Bpod HiFi Module, manual sound level meter
% SoundCal is a struct containing Bpod sound calibration data, stored by default
% in /Bpod_Local/Calibration Files/Sound Calibration/
% volumeRange is a 2-element vector specifying the range of volume to test
% nValueToTest = number of value within volumeRange. These will be log-spaced.
% dbSPL_Target is the target sound level for each frequency in dB SPL
% nSpeakers is 1 for mono and 2 for stereo
%
% Example:
% SoundCal = SoundCalibrationStimuli_Manual([40 80], 10, 60, 2); 
% 1 - Find attenuation factors for taget value (60 dB) for noise and then signal+noise
% for each speaker.
% 2 - Test volume outputted using attenuation factor within volume range set 
% (40dB to 80dB) for nValueToTest (10). 
% 3 - Save calibration file in default location (BpodLocal folder).
%


function SoundCal = SoundCalibrationStimuli_Manual(volumeRange,nValueToTest, dbSPL_Target, nSpeakers)

global BpodSystem
%% Resolve HiFi Module USB port
if (isfield(BpodSystem.ModuleUSB, 'HiFi1'))
    %% Create an instance of the HiFi module
    H = BpodHiFi(BpodSystem.ModuleUSB.HiFi1);
else
    error('Error: To run this protocol, you must first pair the HiFi module with its USB port. Click the USB config button on the Bpod console.')
end

% Load sounds used during protocol to run calibration
computerUsername = char(java.lang.System.getProperty('user.name'));
load(['/Users/' computerUsername '/Documents/MATLAB/Bpod_Gen2/Functions/Calibration/Sound/soundsToCalibrate.mat'])
pathToCalibFiles = ['/Users/' computerUsername '/Documents/MATLAB/Bpod Local/Calibration Files/'];

% General sound params
H.DigitalAttenuation_dB = 0;
H.SamplingRate = 192000;
nTriesPerSound = 20;
soundDuration = 4; % Seconds
AcceptableDifference_dBSPL = 0.5;

if (dbSPL_Target < 10) || (dbSPL_Target > 120)
    error('Error: target dB SPL must be in range [10, 120]')
end
if nSpeakers > 2
    error('Error: this function can calibrate 1 or 2 speakers.')
end

% Setup struct
SoundCal = struct;
for i = 1:nSpeakers
    SoundCal(i).Table = [];
    SoundCal(i).Sounds = Sounds.Stream;
    SoundCal(i).Name = Sounds.Name;
    SoundCal(i).TargetSPL = dbSPL_Target;
    SoundCal(i).LastDateModified = date;
    SoundCal(i).Coefficient = [];
end

%% Calibration loop
speakerNames = {'Left', 'Right'};
for s = 1:nSpeakers
    disp([char(10) 'Begin calibrating ' speakerNames{s} ' speaker.'])
    for n = 1:length(Sounds.Name) 
        attFactor = 0.2;
        found = 0;
        nTries = 0;
        while found == 0
            nTries = nTries + 1;
            if nTries > nTriesPerSound
                error(['Error: Could not resolve an attenuation factor for ' Sounds.Name{n}])
            end
            input([num2str(nTries) ' - Press Enter to play the next sound (' num2str(n) '/' num2str(length(Sounds.Name)) '). This tone = ' Sounds.Name{n} ' , ' num2str(attFactor) ' FS amplitude.'], 's'); 
            sound = Sounds.Stream{n} * attFactor;
            if s == 1
                H.load(1, [sound; zeros(1,length(sound))], 'LoopMode', 1, 'LoopDuration', soundDuration); 
                H.push; pause(.1);
            else
                H.load(1, [zeros(1,length(sound)); sound], 'LoopMode', 1, 'LoopDuration', soundDuration); 
                H.push; pause(.1);
            end
            
            H.play(1);
            pause(soundDuration);
            dbSPL_Measured = input(['Enter dB SPL measured > ']);
            if abs(dbSPL_Measured - dbSPL_Target) <= AcceptableDifference_dBSPL
                SoundCal(s).AttenuationFactor{n} = attFactor;
                found = 1;
            else
                AmpFactor = sqrt(10^((dbSPL_Measured - dbSPL_Target)/10));
                attFactor = attFactor/AmpFactor;
                attFactor2 = input(['Next attenuation factor tested:' num2str(attFactor) '. Alternative attenuation factor to test:' num2str(attFactor) '? ']);
                if attFactor2>0; attFactor=attFactor2; end; clear attFactor2 P yfit
            end
        end
    end
end

%% Save sound calibration file
save([pathToCalibFiles '/SoundCalibrationOngoing.mat'] , 'SoundCal')

%% Test of volume calibration

minVol = volumeRange(1);
maxVol = volumeRange(2);
volumeVector =  logspace(log10(minVol),log10(maxVol),nValueToTest);
speakerNames = {'Left', 'Right'};
for s = 1:nSpeakers
    disp([char(10) 'Begin testing ' speakerNames{s} ' speaker.'])
    for n = 1:length(Sounds.Name) 
        ThisTable = zeros(nValueToTest, 2);
        for v = 1:nValueToTest
            attFactor = SoundCal(s).AttenuationFactor{n};
            % estimate theoritical att factor for volume to test based on targetSPL att factor
            diffSPL = volumeVector(v) - [SoundCal(1,s).TargetSPL];
            diffFactor = sqrt(10.^(diffSPL./10)); 
            attFactor = attFactor*diffFactor;                 
            found = 0;
            nTries = 0;
            while found == 0
                nTries = nTries + 1;
                if nTries > nTriesPerSound
                    error(['Error: Could not resolve an attenuation factor for ' num2str(volumeVector(v))])
                end
                sound = Sounds.Stream{n} * attFactor;
                input([num2str(nTries) ' - Press Enter to play the next tone (' num2str(v) '/' num2str(nValueToTest) '). ' Sounds.Name{n} ' : ' num2str(volumeVector(v)) ' Hz, ' num2str(attFactor) ' FS amplitude.'], 's'); 
                if s == 1
                    H.load(1, [sound; zeros(1,length(sound))], 'LoopMode', 1, 'LoopDuration', soundDuration); 
                    H.push; pause(.1);
                else
                    H.load(1, [zeros(1,length(sound)); sound], 'LoopMode', 1, 'LoopDuration', soundDuration); 
                    H.push; pause(.1);
                end
                H.play(1);
                pause(soundDuration);
                dbSPL_Measured = input(['Enter dB SPL measured > ']);              
                if abs(dbSPL_Measured - volumeVector(v)) <= AcceptableDifference_dBSPL % save attFactor in table
                    ThisTable(v,1) = volumeVector(v);
                    ThisTable(v,2) = attFactor;
                    found = 1;
                else % compute new att factor to test
                    AmpFactor = sqrt(10^((dbSPL_Measured - volumeVector(v))/10)); 
                    attFactor = attFactor/AmpFactor;
                    attFactor2 = input(['Next attenuation factor tested:' num2str(attFactor) '. Alternative attenuation factor to test:' num2str(attFactor) '? ']);
                    if attFactor2>0; attFactor=attFactor2; end; clear attFactor2 P yfit
                end
            end % each attempt to find att factor
        end % each volume value tested
        % add att factors to table for each sound
        ThisTable = [0 0;ThisTable]; % add value zero so that calibration curve goes through zero
        SoundCal(s).Table{n} = ThisTable;
        SoundCal(s).Coefficient{n} = glmfit(ThisTable(:,1),ThisTable(:,2),'binomial');
        save([pathToCalibFiles 'SoundCalibrationOngoing.mat'] , 'SoundCal')
    end % each sound
end % each speaker

answer = questdlg('Successful sound calibration! Replace old calibration file','Yes');
% replace old calibration file and delete temp calibration file
if strcmp(answer,'Yes')
    save([pathToCalibFiles '/SoundCalibration.mat'] , 'SoundCal')
    delete([pathToCalibFiles '/SoundCalibrationOngoing.mat'])
end

