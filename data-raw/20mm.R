
## Data retrieval script for CDFW's 20mm Survey.
## Database is too large to store on GitHub, so query now and save smaller csv files.
## As of 10/13/2021 data are now posted as csv files on EDI, but there is no length data
## so still using ftp site for now.

#########################################################################################
## Retrieve 20mm Survey database copy, save tables, delete database.
## Only run this section when needed.

library(DBI)
library(odbc)

## 20mm Survey url, name of zip file, and name of database within the zip file:
surveyURL <- "https://filelib.wildlife.ca.gov/Public/Delta%20Smelt/20mm_New.zip"
zipFileName <- "20mm_New.zip"
dbName <- "20mm_New.accdb"

## Download and unzip the file:
localZipFile <- file.path(tempdir(),zipFileName)
download.file(url=surveyURL, destfile=localZipFile)
localDbFile <- unzip(zipfile=localZipFile, exdir=file.path(tempdir()))

## Open connection to the database:
dbString <- paste0("Driver={Microsoft Access Driver (*.mdb, *.accdb)};",
									 "Dbq=",localDbFile)
con <- DBI::dbConnect(drv=odbc::odbc(), .connection_string=dbString)

tables <- odbc::dbListTables(conn=con)
tables

## Save select tables:
keepTables <- c("Tow","FishSample","FishLength","Survey","Station",
								"20mmStations","Gear","GearCodesLkp","MeterCorrections","SampleCode")
for(tab in keepTables) {
	tmp <- DBI::dbReadTable(con, tab)
	write.csv(tmp, file=file.path("data-raw","20mm",paste0(tab,".csv")), row.names=FALSE)
}

## Disconnect from database and remove original files:
DBI::dbDisconnect(conn=con)
unlink(localZipFile)
unlink(localDbFile)


#########################################################################################
## Create and save compressed data files using raw tables.

library(dplyr)
library(lubridate)
library(wql)
require(LTMRdata)

raw_data <- file.path("data-raw","20mm")

Survey <- read.csv(file.path(raw_data,"Survey.csv"), stringsAsFactors=FALSE)
Station <- read.csv(file.path(raw_data,"Station.csv"), stringsAsFactors=FALSE)
Tow <- read.csv(file.path(raw_data,"Tow.csv"), stringsAsFactors=FALSE)
Gear <- read.csv(file.path(raw_data,"Gear.csv"), stringsAsFactors=FALSE)
GearCodesLkp <- read.csv(file.path(raw_data,"GearCodesLkp.csv"), stringsAsFactors=FALSE)
MeterCorrections <- read.csv(file.path(raw_data,"MeterCorrections.csv"),
														 stringsAsFactors=FALSE)
TmmStations <- read.csv(file.path(raw_data,"20mmStations.csv"), stringsAsFactors=FALSE)
FishSample <- read.csv(file.path(raw_data,"FishSample.csv"), stringsAsFactors=FALSE)
FishLength <- read.csv(file.path(raw_data,"FishLength.csv"), stringsAsFactors=FALSE)


MeterCorrections_avg <- MeterCorrections %>%
	dplyr::group_by(MeterSerial) %>%
	dplyr::summarize(kFactor_avg=mean(kFactor), .groups="keep") %>%
	dplyr::ungroup()

sample20mm <- Survey %>%
	dplyr::inner_join(Station, by="SurveyID") %>%
	dplyr::inner_join(Tow, by="StationID") %>%
	dplyr::inner_join(Gear, by="TowID") %>%
	dplyr::left_join(GearCodesLkp, by="GearCode") %>%
	dplyr::left_join(TmmStations, by="Station") %>%
	dplyr::mutate(StudyYear=lubridate::year(SampleDate)) %>%
	dplyr::left_join(MeterCorrections, by=c("StudyYear","MeterSerial")) %>%
	dplyr::left_join(MeterCorrections_avg, by="MeterSerial") %>%
	dplyr::filter(GearCode == 2) %>%
	dplyr::mutate(kFactor_final=ifelse(!is.na(kFactor), kFactor, kFactor_avg),
								Tow_volume=1.51*kFactor_final*MeterCheck) %>%
	dplyr::arrange(SampleDate, Survey, Station, TowNum) %>%
	dplyr::mutate(Source="20mm",
				 SampleID=paste(Source, 1:nrow(.)),
				 Tow_direction=NA,
				 ## Tide codes from 20mmDataFileFormat_New_102621.pdf on the CDFW ftp site:
				 Tide=recode(Tide, `1`="High Slack", `2`="Ebb", `3`="Low Slack", `4`="Flood"),
				 TowTime=substring(TowTime,12),
				 Datetime=paste(SampleDate, TowTime),
				 Date=parse_date_time(SampleDate, "%Y-%m-%d", tz="America/Los_Angeles"),
				 Datetime=parse_date_time(if_else(is.na(TowTime), NA_character_, Datetime),
																	"%Y-%m-%d %%H:%M:%S", tz="America/Los_Angeles"),
				 Depth=BottomDepth*0.3048, # Convert depth to m from feet
				 Cable_length=CableOut*0.3048, # Convert to m from feet
				 Method=GearDescription,
				 Temp_surf=Temp,
				 ## Convert conductivity to salinity; TopEC is in micro-S/cm; input should
				 ##		be in milli-S/cm:
				 Sal_surf=wql::ec2pss(TopEC/1000, t=25),
				 Latitude=(LatD + LatM/60 + LatS/3600),
				 Longitude= -(LonD + LonM/60 + LonS/3600)) %>%
	dplyr::select(GearID, Source, Station, Latitude, Longitude, Date, Datetime, Survey,
								TowNum, Depth, SampleID, Method, Tide, Sal_surf, Temp_surf,
								Secchi, Tow_volume, Tow_direction, Cable_length,
								Duration, Turbidity, Comments, Comments.x, Comments.y)


## Note:
## GearID 33397 has two entries for fish code 10 in FishSample
## GearID 35766 has two entries for fish code 2 in FishSample
## Based on lengths, probably a matter of being ID'd in the field vs. in the lab.

fish20mm_totalCatch <- FishSample %>%
	dplyr::select(GearID, FishSampleID, FishCode, Catch)

fish20mm_individLength <- FishSample %>%
	dplyr::inner_join(FishLength, by="FishSampleID") %>%
	dplyr::select(GearID, FishSampleID, FishCode, Length, Catch)
unique(fish20mm_individLength$Length)

fish20mm_lengthFreq_measured <- fish20mm_individLength %>%
	dplyr::filter(!is.na(Length)) %>%
	dplyr::group_by(GearID, FishSampleID, FishCode, Length) %>%
	dplyr::summarize(LengthFrequency=n(), .groups="keep") %>%
	dplyr::ungroup()

fish20mm_adjustedCount <- fish20mm_totalCatch %>%
  dplyr::left_join(fish20mm_lengthFreq_measured,
									 by=c("GearID","FishSampleID","FishCode")) %>%
  dplyr::group_by(GearID, FishSampleID, FishCode) %>%
  dplyr::mutate(TotalMeasured=sum(LengthFrequency, na.rm=T)) %>%
  dplyr::ungroup() %>%
	## Add total catch numbers:
	## There are some cases where the number of fish measured is greater than the
	## catch value in the FishSample table. In these cases, use the number measured.
	dplyr::mutate(CatchNew=ifelse(TotalMeasured > Catch, TotalMeasured, Catch)) %>%
	## Calculate length-frequency-adjusted counts:
  dplyr::mutate(Count=(LengthFrequency/TotalMeasured)*CatchNew) %>%
  dplyr::left_join(Species %>% ## Add species names
										dplyr::select(TMM_Code, Taxa) %>%
										filter(!is.na(TMM_Code)),
									 by=c("FishCode"="TMM_Code"))

## Examine the cases where number measured > catch:
count_mismatch <- subset(fish20mm_adjustedCount, CatchNew != Catch)
nrow(count_mismatch)


## Join sample and fish info:
TMM <- sample20mm %>%
	dplyr::left_join(fish20mm_adjustedCount %>%
										dplyr::select(GearID, FishCode, Taxa, Length,
																	LengthFrequency, Catch, CatchNew, Count),
									 by="GearID") %>%
	## Add reasoning for any NA lengths:
 dplyr::mutate(Length_NA_flag=if_else(is.na(Catch), "No fish caught", NA_character_),
               Station=as.character(Station))

## There are some cases where:
##  -positive catch is indicated in FishSample, but there are no corresponding records
##		in FishLength.
## In these cases, use the Catch value from FishSample as Count and change
##	Length_NA_flag:
index_1 <- which(!is.na(TMM$Catch) & is.na(TMM$Count))
TMM[index_1, ]
TMM$Count[index_1] <- TMM$Catch[index_1]
TMM$Length_NA_flag[index_1] <- "Unknown length"
TMM[index_1, ]

## 2021-10-25: Adam Chorazyczewski of CDFW confirmed that catch for this
## record is 1:
index_2 <- which(as.character(TMM$Date) == "2021-03-23" & TMM$Station == 610 &
                   TMM$TowNum == 1 & TMM$Taxa == "Gasterosteus aculeatus" &
                   is.na(TMM$Catch))
TMM[index_2, ]
TMM[index_2,c("Catch","Count")] <- 1
TMM[index_2,"Length_NA_flag"] <- "Unknown length"
TMM[index_2, ]


## Create final measured lengths data frame:
TMM_measured_lengths <- TMM %>%
	dplyr::select(SampleID, Taxa, Length, LengthFrequency) %>%
	dplyr::rename(Count=LengthFrequency)
nrow(TMM_measured_lengths)
ncol(TMM_measured_lengths)
names(TMM_measured_lengths)


## Now remove extra fields:
TMM <- TMM %>%
	dplyr::select(-GearID, -Duration, -Turbidity, -Comments, -Comments.x,
								-Comments.y, -FishCode, -Catch, -CatchNew,
								-LengthFrequency)
nrow(TMM)
ncol(TMM)
names(TMM)



## Save compressed data to /data:
usethis::use_data(TMM, TMM_measured_lengths, overwrite=TRUE)


