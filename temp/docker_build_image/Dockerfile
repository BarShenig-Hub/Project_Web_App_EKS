# start by pulling the python image
FROM python:3.11-alpine

# switch working directory
WORKDIR /app

# copy the requirements file into the image
COPY ./requirements.txt requirements.txt

# install the dependencies and packages in the requirements file
RUN pip install --upgrade pip
RUN pip install -r requirements.txt

# copy the application
COPY ./Web_Application.py .

# expose the port
EXPOSE 5000

# configure the container to run in an executed manner
CMD ["python", "Web_Application.py"]