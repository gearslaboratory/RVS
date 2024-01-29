FROM ubuntu


RUN apt update -y --allow-unauthenticated 
RUN apt-get -y install nano libboost-all-dev sqlite3 libsqlite3-dev g++ make git

ENV APP_HOME /app
WORKDIR $APP_HOME

RUN git clone https://github.com/gearslaboratory/gigafire-rvs.git
RUN cd gigafire-rvs/newlib && make

ENV PATH="/app/gigafire-rvs/newlib/build:$PATH"


#RUN make RVS/librvs/

#RUN /librvs(.exe) rvs_init



