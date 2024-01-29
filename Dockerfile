FROM ubuntu


RUN apt update -y --allow-unauthenticated 
RUN apt-get -y install nano libboost-all-dev sqlite3 libsqlite3-dev g++ make git

ENV APP_HOME /app
WORKDIR $APP_HOME

RUN git clone https://github.com/gearslaboratory/RVS.git
RUN cd RVS/librvs && make

ENV PATH="/app/RVS/librvs/build:$PATH"




